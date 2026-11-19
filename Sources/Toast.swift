import UIKit

public class Delay: NSObject {
  @available(*, unavailable) private override init() {}
  // `short` and `long` (lowercase) are reserved words in Objective-C
  // so we capitalize them instead of the default `short_` and `long_`
  @objc(Short) public static let short: TimeInterval = 2.0
  @objc(Long) public static let long: TimeInterval = 3.5
}

//
open class Toast: Operation, @unchecked Sendable {

  // MARK: Properties

  /// The toast stays on screen after `start()` returns, so the queue must wait
  /// for `finish()`. On iOS 17.6 and later a synchronous operation is treated as
  /// finished as soon as `start()` returns.
  override open var isAsynchronous: Bool {
    return true
  }

  @objc public var text: String? {
    get { return self.view.text }
    set { self.view.text = newValue }
  }
  
  @objc public var attributedText: NSAttributedString? {
    get { return self.view.attributedText }
    set { self.view.attributedText = newValue }
  }

  @objc public var delay: TimeInterval
  @objc public var duration: TimeInterval

  private var didBeginHold = false

  private var _executing = false
  override open var isExecuting: Bool {
    get {
      return self._executing
    }
    set {
      self.willChangeValue(forKey: "isExecuting")
      self._executing = newValue
      self.didChangeValue(forKey: "isExecuting")
    }
  }

  private var _finished = false
  override open var isFinished: Bool {
    get {
      return self._finished
    }
    set {
      self.willChangeValue(forKey: "isFinished")
      self._finished = newValue
      self.didChangeValue(forKey: "isFinished")
    }
  }


  // MARK: UI

  @objc public var view: ToastView = ToastView()


  // MARK: Initializing

  /// Initializer.
  /// Instantiates `self.view`, so must be called on main thread.
  @objc public init(text: String?, delay: TimeInterval = 0, duration: TimeInterval = Delay.short) {
    self.delay = delay
    self.duration = duration
    super.init()
    self.text = text
  }

  @objc public init(attributedText: NSAttributedString?, delay: TimeInterval = 0, duration: TimeInterval = Delay.short) {
    self.delay = delay
    self.duration = duration
    super.init()
    self.attributedText = attributedText
  }
  

  // MARK: Factory (Deprecated)

  @available(*, deprecated, message: "Use 'init(text:)' instead.")
  public class func makeText(_ text: String) -> Toast {
    return Toast(text: text)
  }

  @available(*, deprecated, message: "Use 'init(text:duration:)' instead.")
  public class func makeText(_ text: String, duration: TimeInterval) -> Toast {
    return Toast(text: text, duration: duration)
  }

  @available(*, deprecated, message: "Use 'init(text:delay:duration:)' instead.")
  public class func makeText(_ text: String?, delay: TimeInterval, duration: TimeInterval) -> Toast {
    return Toast(text: text, delay: delay, duration: duration)
  }


  // MARK: Showing

  @objc public func show(position: ToastPosition = .bottom) {
    self.view.position = position
    ToastCenter.default.add(self)
  }


  // MARK: Cancelling

  open override func cancel() {
    super.cancel()
    self.finish()
    self.view.removeFromSuperview()
  }


  // MARK: Operation Subclassing

  override open func start() {
    let isRunnable = !self.isFinished && !self.isCancelled && !self.isExecuting
    guard isRunnable else { return }
    // Publish executing before start() returns. Otherwise a queue that still
    // treats this operation as synchronous can drop it on the way to main.
    self.isExecuting = true
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.main()
      }
      return
    }
    main()
  }

  override open func main() {
    DispatchQueue.main.async { [weak self] in
      self?.present()
    }
  }

  private func present() {
    guard !self.isCancelled, !self.isFinished else { return }
    self.view.setNeedsLayout()
    self.view.alpha = 0
    ToastWindow.shared.addSubview(self.view)

    let fadeIn = { [weak self] in
      guard let self = self, !self.isCancelled, !self.isFinished else { return }
      UIView.animate(
        withDuration: 0.5,
        delay: 0,
        options: .beginFromCurrentState,
        animations: {
          self.view.alpha = 1
        },
        completion: { _ in
          self.beginHold()
        }
      )
    }

    if self.delay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + self.delay, execute: fadeIn)
    } else {
      fadeIn()
    }
  }

  private func beginHold() {
    guard !self.isCancelled, !self.isFinished, !self.didBeginHold else { return }
    self.didBeginHold = true
    // The first animation committed on a newly created window can be dropped
    // on newer iOS, which used to skip straight to dismiss. Pin the visible
    // state, then hold for `duration` with a timer instead of a no-op animation.
    self.view.alpha = 1
    if ToastCenter.default.isSupportAccessibility {
      #if swift(>=4.2)
      UIAccessibility.post(notification: .announcement, argument: self.view.text)
      #else
      UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.view.text)
      #endif
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + self.duration) { [weak self] in
      self?.dismiss()
    }
  }

  private func dismiss() {
    guard !self.isFinished else { return }
    self.finish()
    let view = self.view
    UIView.animate(
      withDuration: 0.5,
      animations: {
        view.alpha = 0
      },
      completion: { _ in
        view.removeFromSuperview()
      }
    )
  }

  func finish() {
    guard !self.isFinished else { return }
    self.isExecuting = false
    self.isFinished = true
  }

}
