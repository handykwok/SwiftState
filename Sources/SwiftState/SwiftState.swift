// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Combine

/// A `Feedback` struct represents a mechanism for converting a stream of states into a stream of events
/// which can then be fed back into the system. It encapsulates the behavior needed to produce effects
/// that are contingent on state changes. This is commonly used in architectures that support unidirectional data flow,
/// like Redux or Elm, where it can manage side effects in a controlled way.
///
/// The `Feedback` struct is generic over `State` and `Event` types, allowing it to be used with any kind of state and event
/// within a system. It is especially useful in scenarios where the state changes need to trigger side effects,
/// such as network requests, which then produce events that can modify the state further.
///
/// Parameters:
///   - State: The type of state that the system uses.
///   - Event: The type of events that can be produced as a result of state changes.
///
/// Properties:
///   - run: A closure that takes a publisher of states and returns a publisher of events. This closure defines
///     how the feedback loop processes states to produce side effects that are then encapsulated as events.
///
/// Example Usage:
/// ```
/// // Assuming `State` is an enum representing different states of a network request,
/// // and `Event` is an enum representing possible outcomes of a network request.
///
/// let networkFeedback = Feedback<State, Event> { statePublisher in
///     statePublisher
///         .filter { state in
///             switch state {
///             case .loading:
///                 return true
///             default:
///                 return false
///             }
///         }
///         .flatMap { _ in
///             // Simulate a network request which upon completion returns an `Event`.
///             Just(Event.completedSuccessfully).eraseToAnyPublisher()
///         }
///         .eraseToAnyPublisher()
/// }
/// ```
///
/// This code sets up a feedback loop where every time the state is `.loading`, a simulated network request is made,
/// and upon completion, an `Event.completedSuccessfully` is published.
public struct Feedback<State, Event> {
    /// A closure that takes a stream of states as input and returns a stream of events. This function
    /// is where the logic for side effects in response to state changes is implemented.
    let run: (AnyPublisher<State, Never>) -> AnyPublisher<Event, Never>
}

/// Public extension for `Feedback` struct that provides a convenient initializer for creating feedback loops.
/// This initializer allows for the definition of feedback loops using a simple transformation from states to effect publishers.
///
/// The initializer accepts a transformation function, `effects`, which converts a given state into an `Effect` publisher.
/// The returned publisher emits events corresponding to the state-driven effects. This approach is useful for encapsulating
/// the side effects (such as network requests, database reads, etc.) based on the current state of the system.
///
/// Parameters:
///   - Effect: A `Publisher` type that represents the asynchronous operations or side effects driven by state changes.
///
/// Usage:
/// ```
/// let apiRequestFeedback = Feedback<State, Event> { state in
///     switch state {
///     case .requestData:
///         return URLSession.shared
///             .dataTaskPublisher(for: URL(string: "https://example.com/data")!)
///             .map { _ in Event.dataLoaded }
///             .catch { _ in Just(Event.failedToLoad) }
///             .eraseToAnyPublisher()
///     default:
///         return Empty().eraseToAnyPublisher()
///     }
/// }
/// ```
///
/// In this example, the `Feedback` is initialized with a closure that produces an `Effect` based on the current state.
/// When the state is `.requestData`, it triggers a network request and converts the result into an `Event`. If the state
/// is not `.requestData`, it emits no events (using an `Empty` publisher).
///
/// This extension simplifies the creation of feedback loops by abstracting the boilerplate code needed to subscribe to state
/// changes and switch between different effects dynamically.
public extension Feedback {
    /// Initializes a new `Feedback` instance that converts each `State` into an `Effect` publisher, then flattens the resulting events into a single event stream.
    ///
    /// - Parameter effects: A closure that takes the current state and returns a publisher that emits events. This allows for the dynamic creation of side effects based on state changes.
    /// - Throws: Does not throw. It expects that the effects handle their own errors and never fail (`Effect.Failure == Never`).
    init<Effect: Publisher>(effects: @escaping (State) -> Effect) where Effect.Output == Event, Effect.Failure == Never {
        self.run = { state -> AnyPublisher<Event, Never> in
            state
                .map(effects)      // Map each state to its corresponding effect publisher.
                .switchToLatest()  // Flatten the publishers from all state changes into a single stream of events.
                .eraseToAnyPublisher()  // Convert the output to `AnyPublisher` for type erasure.
        }
    }
}

/// Creates a reactive system that manages state based on events, with state transitions being managed
/// by a user-defined reducer function. This system uses a feedback loop architecture, commonly used in reactive programming,
/// to produce and handle side effects based on state changes.
///
/// The `system` function initializes with a state and continuously applies a reducer function to this state
/// whenever an event occurs. Events are generated by the provided feedback loops. This function provides a structured way
/// to manage state and effects in a predictable and controllable manner.
///
/// Parameters:
///   - State: The type of the state that the system manages.
///   - Event: The type of events that the system processes.
///   - Scheduler: The scheduler on which to run the state updates. This is typically used to control on which
///                queue the state processing and event handling happens (e.g., main queue, background queue).
///
/// - Parameters:
///   - initial: The initial state of the system.
///   - reduce: A closure that describes how the state changes in response to each event. This reducer function
///             takes the current state and an event, and produces a new state.
///   - scheduler: The scheduler on which state updates should be received. This affects where the reduce function and
///                feedback effects will execute, ensuring the correct threading behavior.
///   - feedbacks: An array of `Feedback` loops that monitor the state and produce events that lead to state mutations.
///
/// - Returns: A publisher that emits the current state of the system every time it is updated. It never fails (`Never`).
///
/// Usage:
/// ```
/// let systemPublisher = Publishers.system(
///     initial: MyState.initial,
///     reduce: { state, event in
///         switch event {
///         case .userDidSomething:
///             return MyState.modified
///         default:
///             return state
///         }
///     },
///     scheduler: DispatchQueue.main,
///     feedbacks: [
///         myFeedbackLoop
///     ]
/// )
/// ```
///
/// This setup creates a system where `MyState` is modified in response to `.userDidSomething` events. The events are generated
/// by `myFeedbackLoop`, which might listen to user actions or other external changes, and then run them on the main dispatch queue.
extension Publishers {
    
    public static func system<State, Event, Scheduler: Combine.Scheduler>(
        initial: State,
        reduce: @escaping (State, Event) -> State,
        scheduler: Scheduler,
        feedbacks: [Feedback<State, Event>]
    ) -> AnyPublisher<State, Never> {
        
        let state = CurrentValueSubject<State, Never>(initial)
        
        let events = feedbacks.map { feedback in feedback.run(state.eraseToAnyPublisher()) }
        
        return Deferred {
            Publishers.MergeMany(events)
                .receive(on: scheduler)
                .scan(initial, reduce)
                .handleEvents(receiveOutput: state.send)
                .receive(on: scheduler)
                .prepend(initial)
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
}
