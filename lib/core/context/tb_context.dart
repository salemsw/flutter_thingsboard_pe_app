import 'dart:async';
import 'dart:io';

import 'package:device_info/device_info.dart';
import 'package:fluro/fluro.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:thingsboard_app/modules/main/main_page.dart';
import 'package:thingsboard_app/utils/services/widget_action_handler.dart';
import 'package:thingsboard_client/thingsboard_client.dart';
import 'package:thingsboard_app/utils/services/tb_secure_storage.dart';
import 'package:thingsboard_app/constants/api_path.dart';
import 'package:thingsboard_app/core/context/tb_context_widget.dart';

enum NotificationType {
  info,
  warn,
  success,
  error
}

class TbLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    for (var line in event.lines) {
      debugPrint(line);
    }
  }
}

class TbLogsFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    if (kReleaseMode) {
      return event.level.index >= Level.warning.index;
    } else {
      return true;
    }
  }
}

class TbLogger {
  final _logger = Logger(
      filter: TbLogsFilter(),
      printer: PrefixPrinter(
          PrettyPrinter(
              methodCount: 0,
              errorMethodCount: 8,
              lineLength: 200,
              colors: false,
              printEmojis: true,
              printTime: false
          )
      ),
      output: TbLogOutput()
  );

  void verbose(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.v(message, error, stackTrace);
  }

  void debug(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.d(message, error, stackTrace);
  }

  void info(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.i(message, error, stackTrace);
  }

  void warn(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.w(message, error, stackTrace);
  }

  void error(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(message, error, stackTrace);
  }

  void fatal(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.wtf(message, error, stackTrace);
  }
}


class TbContext {
  static final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
  bool _initialized = false;
  bool isUserLoaded = false;
  bool isAuthenticated = false;
  User? userDetails;
  HomeDashboardInfo? homeDashboard;
  final _isLoadingNotifier = ValueNotifier<bool>(false);
  final _log = TbLogger();
  late final _widgetActionHandler;
  late final AndroidDeviceInfo? _androidInfo;
  late final IosDeviceInfo? _iosInfo;

  GlobalKey<ScaffoldMessengerState> messengerKey = GlobalKey<ScaffoldMessengerState>();
  late ThingsboardClient tbClient;

  final FluroRouter router;
  final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

  TbContextState? currentState;

  TbContext(this.router) {
    _widgetActionHandler = WidgetActionHandler(this);
  }

  TbLogger get log => _log;
  WidgetActionHandler get widgetActionHandler => _widgetActionHandler;

  Future<void> init() async {
    assert(() {
      if (_initialized) {
        throw StateError('TbContext already initialized!');
      }
      return true;
    }());
    _initialized = true;
    tbClient = ThingsboardClient(thingsBoardApiEndpoint,
                                 storage: TbSecureStorage(),
                                 onUserLoaded: onUserLoaded,
                                 onError: onError,
                                 onLoadStarted: onLoadStarted,
                                 onLoadFinished: onLoadFinished,
                                 computeFunc: <Q, R>(callback, message) => compute(callback, message));
    try {
      if (Platform.isAndroid) {
        _androidInfo = await deviceInfoPlugin.androidInfo;
      } else if (Platform.isIOS) {
        _iosInfo = await deviceInfoPlugin.iosInfo;
      }
      await tbClient.init();
    } catch (e, s) {
      log.error('Failed to init tbContext: $e', e, s);
    }
  }

  void onError(ThingsboardError tbError) {
    log.error('onError', tbError, tbError.getStackTrace());
    showErrorNotification(tbError.message!);
  }

  void showErrorNotification(String message, {Duration? duration}) {
    showNotification(message, NotificationType.error, duration: duration);
  }

  void showInfoNotification(String message, {Duration? duration}) {
    showNotification(message, NotificationType.info, duration: duration);
  }

  void showWarnNotification(String message, {Duration? duration}) {
    showNotification(message, NotificationType.warn, duration: duration);
  }

  void showSuccessNotification(String message, {Duration? duration}) {
    showNotification(message, NotificationType.success, duration: duration);
  }

  void showNotification(String message, NotificationType type, {Duration? duration}) {
    duration ??= const Duration(days: 1);
    Color backgroundColor;
    var textColor = Color(0xFFFFFFFF);
    switch(type) {
      case NotificationType.info:
        backgroundColor = Color(0xFF323232);
        break;
      case NotificationType.warn:
        backgroundColor = Color(0xFFdc6d1b);
        break;
      case NotificationType.success:
        backgroundColor = Color(0xFF008000);
        break;
      case NotificationType.error:
        backgroundColor = Color(0xFF800000);
        break;
    }
    final snackBar = SnackBar(
      duration: duration,
      backgroundColor: backgroundColor,
      content: Text(message,
        style: TextStyle(
          color: textColor
        ),
      ),
      action: SnackBarAction(
        label: 'Close',
        textColor: textColor,
        onPressed: () {
          messengerKey.currentState!.hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss);
        },
      ),
    );
    messengerKey.currentState!.removeCurrentSnackBar();
    messengerKey.currentState!.showSnackBar(snackBar);
  }

  void hideNotification() {
    messengerKey.currentState!.removeCurrentSnackBar();
  }

  void onLoadStarted() {
    log.debug('On load started.');
    _isLoadingNotifier.value = true;
  }

  void onLoadFinished() {
    log.debug('On load finished.');
    _isLoadingNotifier.value = false;
  }

  Future<void> onUserLoaded() async {
    try {
      log.debug('onUserLoaded: isAuthenticated=${tbClient.isAuthenticated()}');
      isUserLoaded = true;
      isAuthenticated = tbClient.isAuthenticated();
      if (tbClient.isAuthenticated()) {
        log.debug('authUser: ${tbClient.getAuthUser()}');
        if (tbClient.getAuthUser()!.userId != null) {
          try {
            userDetails = await tbClient.getUserService().getUser(
                tbClient.getAuthUser()!.userId!);
            homeDashboard = await tbClient.getDashboardService().getHomeDashboardInfo();
          } catch (e) {
            tbClient.logout();
          }
        }
      } else {
        userDetails = null;
        homeDashboard = null;
      }
      updateRouteState();

    } catch (e, s) {
      log.error('Error: $e', e, s);
    }
  }

  void updateRouteState() {
    if (currentState != null) {
      if (tbClient.isAuthenticated()) {
        var defaultDashboardId = _defaultDashboardId();
        if (defaultDashboardId != null) {
          bool fullscreen = _userForceFullscreen();
          navigateTo('/dashboard/$defaultDashboardId?fullscreen=$fullscreen', replace: true, transition: TransitionType.fadeIn, transitionDuration: Duration(milliseconds: 750));
        } else {
          navigateTo('/home', replace: true, transition: TransitionType.fadeIn, transitionDuration: Duration(milliseconds: 750));
        }
      } else {
        navigateTo('/login', replace: true, clearStack: true, transition: TransitionType.fadeIn, transitionDuration: Duration(milliseconds: 750));
      }
    }
  }

  String? _defaultDashboardId() {
    if (userDetails != null && userDetails!.additionalInfo != null) {
      return userDetails!.additionalInfo!['defaultDashboardId'];
    }
    return null;
  }

  bool _userForceFullscreen() {
    return tbClient.getAuthUser()!.isPublic ||
           (userDetails != null && userDetails!.additionalInfo != null &&
               userDetails!.additionalInfo!['defaultDashboardFullscreen'] == true);
  }

  bool isPhysicalDevice() {
    if (Platform.isAndroid) {
      return _androidInfo!.isPhysicalDevice;
    } else if (Platform.isIOS) {
      return _iosInfo!.isPhysicalDevice;
    } else {
      return false;
    }
  }

  Future<dynamic> navigateTo(String path, {bool replace = false, bool clearStack = false, TransitionType? transition, Duration? transitionDuration}) async {
    if (currentState != null) {
      hideNotification();
      if (currentState is TbMainState) {
        var mainState = currentState as TbMainState;
        if (mainState.canNavigate(path) && !replace) {
          mainState.navigateToPath(path);
          return;
        }
      }
      if (TbMainNavigationItem.isMainPageState(this, path)) {
        replace = true;
        clearStack = true;
      }
      if (transition == null) {
        if (replace) {
          transition = TransitionType.fadeIn;
        } else {
          transition = TransitionType.inFromRight;
        }
      }
      return await router.navigateTo(currentState!.context, path, transition: transition, transitionDuration: transitionDuration, replace: replace, clearStack: clearStack);
    }
  }

  void pop<T>([T? result]) {
    if (currentState != null) {
      router.pop<T>(currentState!.context, result);
    }
  }
}

mixin HasTbContext {
  late final TbContext _tbContext;

  void setTbContext(TbContext tbContext) {
    _tbContext = tbContext;
  }

  void setupCurrentState(TbContextState currentState) {
    _tbContext.currentState = currentState;
  }

  void setupTbContext(TbContextState currentState) {
    _tbContext = currentState.widget.tbContext;
  }

  TbContext get tbContext => _tbContext;

  TbLogger get log => _tbContext.log;

  bool get isPhysicalDevice => _tbContext.isPhysicalDevice();

  WidgetActionHandler get widgetActionHandler => _tbContext.widgetActionHandler;

  ValueNotifier<bool> get loadingNotifier => _tbContext._isLoadingNotifier;

  ThingsboardClient get tbClient => _tbContext.tbClient;

  Future<void> initTbContext() async {
    await _tbContext.init();
  }

  Future<dynamic> navigateTo(String path, {bool replace = false, bool clearStack = false}) => _tbContext.navigateTo(path, replace: replace, clearStack: clearStack);

  void pop<T>([T? result]) => _tbContext.pop<T>(result);

  void hideNotification() => _tbContext.hideNotification();

  void showErrorNotification(String message, {Duration? duration}) => _tbContext.showErrorNotification(message, duration: duration);

  void showInfoNotification(String message, {Duration? duration}) => _tbContext.showInfoNotification(message, duration: duration);

  void showWarnNotification(String message, {Duration? duration}) => _tbContext.showWarnNotification(message, duration: duration);

  void showSuccessNotification(String message, {Duration? duration}) => _tbContext.showSuccessNotification(message, duration: duration);

  void subscribeRouteObserver(TbPageState pageState) {
    _tbContext.routeObserver.subscribe(pageState, ModalRoute.of(pageState.context) as PageRoute);
  }

  void unsubscribeRouteObserver(TbPageState pageState) {
    _tbContext.routeObserver.unsubscribe(pageState);
  }

}