import Dispatch
import Foundation
import enum Result.NoError

/// Represents an action that will do some work when executed with a value of
/// type `Input`, then return zero or more values of type `Output` and/or fail
/// with an error of type `Error`. If no failure should be possible, NoError can
/// be specified for the `Error` parameter.
///
/// Actions enforce serial execution. Any attempt to execute an action multiple
/// times concurrently will return an error.
public final class Action<Input, Output, Error: Swift.Error> {
	private let deinitToken: Lifetime.Token

	private let executeClosure: (_ state: Any, _ input: Input) -> SignalProducer<Output, Error>
	private let eventsObserver: Signal<Event<Output, Error>, NoError>.Observer
	private let disabledErrorsObserver: Signal<(), NoError>.Observer

	/// The lifetime of the Action.
	public let lifetime: Lifetime

	/// A signal of all events generated from applications of the Action.
	///
	/// In other words, this will send every `Event` from every signal generated
	/// by each SignalProducer returned from apply() except `ActionError.disabled`.
	public let events: Signal<Event<Output, Error>, NoError>

	/// A signal of all values generated from applications of the Action.
	///
	/// In other words, this will send every value from every signal generated
	/// by each SignalProducer returned from apply() except `ActionError.disabled`.
	public let values: Signal<Output, NoError>

	/// A signal of all errors generated from applications of the Action.
	///
	/// In other words, this will send errors from every signal generated by
	/// each SignalProducer returned from apply() except `ActionError.disabled`.
	public let errors: Signal<Error, NoError>

	/// A signal which is triggered by `ActionError.disabled`.
	public let disabledErrors: Signal<(), NoError>

	/// A signal of all completed events generated from applications of the action.
	///
	/// In other words, this will send completed events from every signal generated
	/// by each SignalProducer returned from apply().
	public let completed: Signal<(), NoError>

	/// Whether the action is currently executing.
	public let isExecuting: Property<Bool>

	/// Whether the action is currently enabled.
	public let isEnabled: Property<Bool>

	private let state: MutableProperty<ActionState>

	/// Initializes an action that will be conditionally enabled based on the
	/// value of `state`. Creates a `SignalProducer` for each input and the
	/// current value of `state`.
	///
	/// - note: `Action` guarantees that changes to `state` are observed in a
	///         thread-safe way. Thus, the value passed to `isEnabled` will
	///         always be identical to the value passed to `execute`, for each
	///         application of the action.
	///
	/// - note: This initializer should only be used if you need to provide
	///         custom input can also influence whether the action is enabled.
	///         The various convenience initializers should cover most use cases.
	///
	/// - parameters:
	///   - state: A property that provides the current state of the action
	///            whenever `apply()` is called.
	///   - enabledIf: A predicate that, given the current value of `state`,
	///                returns whether the action should be enabled.
	///   - execute: A closure that returns the `SignalProducer` returned by
	///              calling `apply(Input)` on the action, optionally using
	///              the current value of `state`.
	public init<State: PropertyProtocol>(state property: State, enabledIf isEnabled: @escaping (State.Value) -> Bool, _ execute: @escaping (State.Value, Input) -> SignalProducer<Output, Error>) {
		deinitToken = Lifetime.Token()
		lifetime = Lifetime(deinitToken)

		executeClosure = { state, input in execute(state as! State.Value, input) }

		(events, eventsObserver) = Signal<Event<Output, Error>, NoError>.pipe()
		(disabledErrors, disabledErrorsObserver) = Signal<(), NoError>.pipe()

		values = events.map { $0.value }.skipNil()
		errors = events.map { $0.error }.skipNil()
		completed = events.filter { $0.isCompleted }.map { _ in }

		let initial = ActionState(isExecuting: false, value: property.value, isEnabled: { isEnabled($0 as! State.Value) })
		state = MutableProperty(initial)

		property.signal
			.take(during: state.lifetime)
			.observeValues { [weak state] newValue in
				state?.modify {
					$0.value = newValue
				}
			}

		self.isEnabled = state.map { $0.isEnabled }
		self.isExecuting = state.map { $0.isExecuting }
	}

	/// Initializes an action that will be conditionally enabled, and creates a
	/// `SignalProducer` for each input.
	///
	/// - parameters:
	///   - enabledIf: Boolean property that shows whether the action is
	///                enabled.
	///   - execute: A closure that returns the signal producer returned by
	///              calling `apply(Input)` on the action.
	public convenience init<P: PropertyProtocol>(enabledIf property: P, _ execute: @escaping (Input) -> SignalProducer<Output, Error>) where P.Value == Bool {
		self.init(state: property, enabledIf: { $0 }) { _, input in
			execute(input)
		}
	}

	/// Initializes an action that will be enabled by default, and creates a
	/// SignalProducer for each input.
	///
	/// - parameters:
	///   - execute: A closure that returns the signal producer returned by
	///              calling `apply(Input)` on the action.
	public convenience init(_ execute: @escaping (Input) -> SignalProducer<Output, Error>) {
		self.init(enabledIf: Property(value: true), execute)
	}

	deinit {
		eventsObserver.sendCompleted()
		disabledErrorsObserver.sendCompleted()
	}

	/// Creates a SignalProducer that, when started, will execute the action
	/// with the given input, then forward the results upon the produced Signal.
	///
	/// - note: If the action is disabled when the returned SignalProducer is
	///         started, the produced signal will send `ActionError.disabled`,
	///         and nothing will be sent upon `values` or `errors` for that
	///         particular signal.
	///
	/// - parameters:
	///   - input: A value that will be passed to the closure creating the signal
	///            producer.
	public func apply(_ input: Input) -> SignalProducer<Output, ActionError<Error>> {
		return SignalProducer { observer, disposable in
			let startingState = self.state.modify { state -> Any? in
				if state.isEnabled {
					state.isExecuting = true
					return state.value
				} else {
					return nil
				}
			}

			guard let state = startingState else {
				observer.send(error: .disabled)
				self.disabledErrorsObserver.send(value: ())
				return
			}

			self.executeClosure(state, input).startWithSignal { signal, signalDisposable in
				disposable += signalDisposable

				signal.observe { event in
					observer.action(event.mapError(ActionError.producerFailed))
					self.eventsObserver.send(value: event)
				}
			}

			disposable += {
				self.state.modify {
					$0.isExecuting = false
				}
			}
		}
	}
}

private struct ActionState {
	var isExecuting: Bool
	var value: Any
	private let userEnabled: (Any) -> Bool

	init(isExecuting: Bool, value: Any, isEnabled: @escaping (Any) -> Bool) {
		self.isExecuting = isExecuting
		self.value = value
		self.userEnabled = isEnabled
	}

	/// Whether the action should be enabled for the given combination of user
	/// enabledness and executing status.
	fileprivate var isEnabled: Bool {
		return userEnabled(value) && !isExecuting
	}
}

public protocol ActionProtocol: BindingTargetProtocol {
	/// The type of argument to apply the action to.
	associatedtype Input
	/// The type of values returned by the action.
	associatedtype Output
	/// The type of error when the action fails. If errors aren't possible then
	/// `NoError` can be used.
	associatedtype Error: Swift.Error

	/// Initializes an action that will be conditionally enabled based on the
	/// value of `state`. Creates a `SignalProducer` for each input and the
	/// current value of `state`.
	///
	/// - note: `Action` guarantees that changes to `state` are observed in a
	///         thread-safe way. Thus, the value passed to `isEnabled` will
	///         always be identical to the value passed to `execute`, for each
	///         application of the action.
	///
	/// - note: This initializer should only be used if you need to provide
	///         custom input can also influence whether the action is enabled.
	///         The various convenience initializers should cover most use cases.
	///
	/// - parameters:
	///   - state: A property that provides the current state of the action
	///            whenever `apply()` is called.
	///   - enabledIf: A predicate that, given the current value of `state`,
	///                returns whether the action should be enabled.
	///   - execute: A closure that returns the `SignalProducer` returned by
	///              calling `apply(Input)` on the action, optionally using
	///              the current value of `state`.
	init<State: PropertyProtocol>(state property: State, enabledIf isEnabled: @escaping (State.Value) -> Bool, _ execute: @escaping (State.Value, Input) -> SignalProducer<Output, Error>)

	/// Whether the action is currently enabled.
	var isEnabled: Property<Bool> { get }

	/// Extracts an action from the receiver.
	var action: Action<Input, Output, Error> { get }

	/// Creates a SignalProducer that, when started, will execute the action
	/// with the given input, then forward the results upon the produced Signal.
	///
	/// - note: If the action is disabled when the returned SignalProducer is
	///         started, the produced signal will send `ActionError.disabled`,
	///         and nothing will be sent upon `values` or `errors` for that
	///         particular signal.
	///
	/// - parameters:
	///   - input: A value that will be passed to the closure creating the signal
	///            producer.
	func apply(_ input: Input) -> SignalProducer<Output, ActionError<Error>>
}

extension ActionProtocol {
	public func consume(_ value: Input) {
		apply(value).start()
	}
}

extension Action: ActionProtocol {
	public var action: Action {
		return self
	}
}

extension ActionProtocol where Input == Void {
	/// Initializes an action that uses an `Optional` property for its input,
	/// and is disabled whenever the input is `nil`. When executed, a `SignalProducer`
	/// is created with the current value of the input.
	///
	/// - parameters:
	///   - input: An `Optional` property whose current value is used as input
	///            whenever the action is executed. The action is disabled
	///            whenever the value is `nil`.
	///   - execute: A closure to return a new `SignalProducer` based on the
	///              current value of `input`.
	public init<P: PropertyProtocol, T>(input: P, _ execute: @escaping (T) -> SignalProducer<Output, Error>) where P.Value == T? {
		self.init(state: input, enabledIf: { $0 != nil }) { input, _ in
			execute(input!)
		}
	}

	/// Initializes an action that uses a property for its input. When executed,
	/// a `SignalProducer` is created with the current value of the input.
	///
	/// - parameters:
	///   - input: A property whose current value is used as input
	///            whenever the action is executed.
	///   - execute: A closure to return a new `SignalProducer` based on the
	///              current value of `input`.
	public init<P: PropertyProtocol, T>(input: P, _ execute: @escaping (T) -> SignalProducer<Output, Error>) where P.Value == T {
		self.init(input: input.map(Optional.some), execute)
	}
}

/// The type of error that can occur from Action.apply, where `Error` is the
/// type of error that can be generated by the specific Action instance.
public enum ActionError<Error: Swift.Error>: Swift.Error {
	/// The producer returned from apply() was started while the Action was
	/// disabled.
	case disabled

	/// The producer returned from apply() sent the given error.
	case producerFailed(Error)
}

public func == <Error: Equatable>(lhs: ActionError<Error>, rhs: ActionError<Error>) -> Bool {
	switch (lhs, rhs) {
	case (.disabled, .disabled):
		return true

	case let (.producerFailed(left), .producerFailed(right)):
		return left == right

	default:
		return false
	}
}
