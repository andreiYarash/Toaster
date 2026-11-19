import UIKit

/// Owns the toast hierarchy so UIKit never installs the app's view controller
/// into this window. Sharing that controller makes the first presentation
/// rebuild the window and drop the toast.
private final class ToastRootViewController: UIViewController {

  override func loadView() {
    let container = UIView()
    container.backgroundColor = .clear
    container.isOpaque = false
    container.isUserInteractionEnabled = false
    view = container
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return ToastWindow.hostViewController()?.preferredStatusBarStyle ?? super.preferredStatusBarStyle
  }

  override var prefersStatusBarHidden: Bool {
    return ToastWindow.hostViewController()?.prefersStatusBarHidden ?? super.prefersStatusBarHidden
  }

  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
    return ToastWindow.hostViewController()?.preferredStatusBarUpdateAnimation ?? super.preferredStatusBarUpdateAnimation
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    if let host = ToastWindow.hostViewController() {
      return host.supportedInterfaceOrientations
    }
    return UIApplication.shared.supportedInterfaceOrientations(for: ToastWindow.hostWindow())
  }

  override var shouldAutorotate: Bool {
    return ToastWindow.hostViewController()?.shouldAutorotate ?? super.shouldAutorotate
  }
}

open class ToastWindow: UIWindow {

  // MARK: - Public Property

  public static let shared: ToastWindow = {
    let host = ToastWindow.hostWindow()
    let frame = host?.bounds ?? UIScreen.main.bounds
    return ToastWindow(frame: frame, mainWindow: host)
  }()

  /// Keep a stable root so the app controller is never moved into this window.
  override open var rootViewController: UIViewController? {
    get {
      return super.rootViewController
    }
    set {
      guard !self.didLockRootViewController else { return }
      self.didLockRootViewController = newValue != nil
      super.rootViewController = newValue
    }
  }

  /// Overlay windows must not take key status. Becoming key on the first
  /// show cancels the in-flight toast and is what made only the first one short.
  @available(iOS 15.0, *)
  override open var canBecomeKey: Bool {
    return false
  }

  var shouldRotateManually: Bool {
    let iPad = UIDevice.current.userInterfaceIdiom == .pad
    let application = UIApplication.shared
    let window = application.delegate?.window ?? nil
    let supportsAllOrientations = application.supportedInterfaceOrientations(for: window) == .all

    let info = Bundle.main.infoDictionary
    let requiresFullScreen = (info?["UIRequiresFullScreen"] as? NSNumber)?.boolValue == true
    let hasLaunchStoryboard = info?["UILaunchStoryboardName"] != nil

    if #available(iOS 9, *), iPad && supportsAllOrientations && !requiresFullScreen && hasLaunchStoryboard {
      return false
    }
    return true
  }


  // MARK: - Private Property

  private let toastRootViewController = ToastRootViewController()

  private var didLockRootViewController = false

  private var originalSubviews = NSPointerArray.weakObjects()

  private weak var mainWindow: UIWindow?

  private static var isResolvingHost = false


  // MARK: - Initializing
  public init(frame: CGRect, mainWindow: UIWindow?) {
    super.init(frame: frame)
    self.mainWindow = mainWindow
    self.isUserInteractionEnabled = false
    self.gestureRecognizers = nil
    #if swift(>=4.2)
    self.windowLevel = .init(rawValue: .greatestFiniteMagnitude)
    let didChangeStatusBarOrientationName = UIApplication.didChangeStatusBarOrientationNotification
    let didBecomeActiveName = UIApplication.didBecomeActiveNotification
    let keyboardWillShowName = UIWindow.keyboardWillShowNotification
    let keyboardDidHideName = UIWindow.keyboardDidHideNotification
    #else
    self.windowLevel = .greatestFiniteMagnitude
    let didChangeStatusBarOrientationName = NSNotification.Name.UIApplicationDidChangeStatusBarOrientation
    let didBecomeActiveName = NSNotification.Name.UIApplicationDidBecomeActive
    let keyboardWillShowName = NSNotification.Name.UIKeyboardWillShow
    let keyboardDidHideName = NSNotification.Name.UIKeyboardDidHide
    #endif
    self.backgroundColor = .clear
    self.isOpaque = false

    if #available(iOS 13.0, *), self.windowScene == nil {
      self.windowScene = ToastWindow.activeWindowScene()
    }
    self.installRootViewController()
    // Scene attachment can clear the controller. Put it back before showing.
    self.installRootViewController()
    self.isHidden = false
    self.handleRotate(UIApplication.shared.statusBarOrientation)
    self.layoutIfNeeded()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(self.statusBarOrientationDidChange),
      name: didChangeStatusBarOrientationName,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(self.applicationDidBecomeActive),
      name: didBecomeActiveName,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(self.keyboardWillShow),
      name: keyboardWillShowName,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(self.keyboardDidHide),
      name: keyboardDidHideName,
      object: nil
    )
  }

  required public init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented: please use ToastWindow.shared")
  }


  // MARK: - Public method

  override open func addSubview(_ view: UIView) {
    // UIWindow inserts the root controller's view through addSubview. Routing
    // that view into itself builds a layer cycle and crashes on isHidden = false.
    if view === self.toastRootViewController.view {
      super.addSubview(view)
      return
    }
    self.preparedContainerView().addSubview(view)
    self.originalSubviews.addPointer(Unmanaged.passUnretained(view).toOpaque())
    // Only the keyboard window needs the toast reparented. Moving it onto
    // whichever window happens to be last drops the first toast when that
    // window is a temporary system window.
    guard KeyboardObserver.shared.didKeyboardShow, let topWindow = self.topWindow() else { return }
    topWindow.addSubview(view)
  }

  open override func becomeKey() {
    super.becomeKey()
    let host = self.mainWindow ?? ToastWindow.hostWindow()
    if let host = host, host !== self {
      host.makeKey()
    }
  }


  // MARK: - Private method

  fileprivate static func hostWindow() -> UIWindow? {
    let delegateWindow = UIApplication.shared.delegate?.window ?? nil
    if let delegateWindow = delegateWindow, !(delegateWindow is ToastWindow) {
      return delegateWindow
    }
    guard #available(iOS 13.0, *) else { return nil }
    guard let scene = ToastWindow.activeWindowScene() else { return nil }
    return scene.windows.first { !($0 is ToastWindow) }
  }

  fileprivate static func hostViewController() -> UIViewController? {
    if ToastWindow.isResolvingHost { return nil }
    ToastWindow.isResolvingHost = true
    defer { ToastWindow.isResolvingHost = false }
    return ToastWindow.hostWindow()?.rootViewController
  }

  @available(iOS 13.0, *)
  fileprivate static func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
      return active
    }
    return scenes.first
  }

  private func installRootViewController() {
    guard super.rootViewController !== self.toastRootViewController else {
      self.didLockRootViewController = true
      return
    }
    self.didLockRootViewController = false
    self.rootViewController = self.toastRootViewController
  }

  private func preparedContainerView() -> UIView {
    self.toastRootViewController.loadViewIfNeeded()
    guard let container = self.toastRootViewController.view else {
      let fallback = UIView(frame: self.bounds)
      fallback.backgroundColor = .clear
      fallback.isOpaque = false
      fallback.isUserInteractionEnabled = false
      super.addSubview(fallback)
      return fallback
    }
    if container.bounds.size == .zero {
      container.frame = self.bounds
    }
    if container.window == nil {
      super.addSubview(container)
    }
    return container
  }

  @objc private func statusBarOrientationDidChange() {
    let orientation = UIApplication.shared.statusBarOrientation
    self.handleRotate(orientation)
  }

  @objc private func applicationDidBecomeActive() {
    let orientation = UIApplication.shared.statusBarOrientation
    self.handleRotate(orientation)
  }

  @objc private func keyboardWillShow() {
    guard let topWindow = self.topWindow(),
      let subviews = self.originalSubviews.allObjects as? [UIView] else { return }
    for subview in subviews {
      topWindow.addSubview(subview)
    }
  }

  @objc private func keyboardDidHide() {
    guard let subviews = self.originalSubviews.allObjects as? [UIView] else { return }
    let container = self.preparedContainerView()
    for subview in subviews {
      container.addSubview(subview)
    }
  }

  private func handleRotate(_ orientation: UIInterfaceOrientation) {
    let angle = self.angleForOrientation(orientation)
    if self.shouldRotateManually {
      self.transform = CGAffineTransform(rotationAngle: CGFloat(angle))
    }

    let reference = ToastWindow.hostWindow() ?? UIApplication.shared.windows.first { !($0 is ToastWindow) }
    if let window = reference {
      if orientation.isPortrait || !self.shouldRotateManually {
        self.frame.size.width = window.bounds.size.width
        self.frame.size.height = window.bounds.size.height
      } else {
        self.frame.size.width = window.bounds.size.height
        self.frame.size.height = window.bounds.size.width
      }
    }

    self.frame.origin = .zero

    DispatchQueue.main.async {
      ToastCenter.default.currentToast?.view.setNeedsLayout()
    }
  }

  private func angleForOrientation(_ orientation: UIInterfaceOrientation) -> Double {
    switch orientation {
    case .landscapeLeft: return -.pi / 2
    case .landscapeRight: return .pi / 2
    case .portraitUpsideDown: return .pi
    default: return 0
    }
  }

  private func topWindow() -> UIWindow? {
    if let window = UIApplication.shared.windows.last(where: {
      // https://github.com/devxoul/Toaster/issues/152
      KeyboardObserver.shared.didKeyboardShow || $0.isOpaque
    }), window !== self {
      return window
    }
    return nil
  }

}
