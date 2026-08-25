#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static NSString * const MWRussianSocket = @"/var/jb/var/run/macws-onboarding.sock";

static NSString * MWTranslate(NSString *text) {
    if (!text.length) return text;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"就绪": @"Готово",
            @"操作失败": @"Операция не выполнена",
            @"检查并修复启动环境…": @"Проверка и исправление среды запуска…",
            @"等待 WindowServer、触控与窗口流…": @"Ожидание WindowServer, сенсорного ввода и потока окон…",
            @"停止 macOS GUI…": @"Остановка графического интерфейса macOS…",
            @"停止工作区并修复启动环境…": @"Остановка рабочего пространства и исправление запуска…",
            @"重新签名并恢复信任缓存…": @"Повторная подпись и восстановление trust cache…",
            @"执行安全恢复…": @"Выполнение безопасного восстановления…",
            @"启动 macOS 应用…": @"Запуск приложения macOS…",
            @"启动 macOS 路径…": @"Запуск пути macOS…",
            @"请求刷新共享帧…": @"Запрос обновления общего кадра…",
            @"安全保护已触发": @"Сработала защита",
            @"正在生成启动配置…": @"Создание конфигурации запуска…",
            @"正在清理旧的服务状态…": @"Очистка старого состояния служб…",
            @"正在准备应用运行环境…": @"Подготовка среды приложений…",
            @"正在验证图形启动条件…": @"Проверка графических условий запуска…",
            @"正在启动安全保护…": @"Запуск защиты…",
            @"正在启动 macOS 系统服务…": @"Запуск системных служб macOS…",
            @"正在等待第一帧画面…": @"Ожидание первого кадра…",
            @"macOS 工作区已就绪": @"Рабочее пространство macOS готово",
            @"Ready": @"Готово",
            @"Operation Failed": @"Операция не выполнена",
            @"Checking and repairing the environment…": @"Проверка и исправление среды запуска…",
            @"Waiting for WindowServer, touch, and window streaming…": @"Ожидание WindowServer, сенсорного ввода и потока окон…",
            @"Stopping the macOS GUI…": @"Остановка графического интерфейса macOS…",
            @"Stopping and repairing the workspace…": @"Остановка рабочего пространства и исправление запуска…",
            @"Re-signing and restoring the trust cache…": @"Повторная подпись и восстановление trust cache…",
            @"Running safe recovery…": @"Выполнение безопасного восстановления…",
            @"Launching a macOS app…": @"Запуск приложения macOS…",
            @"Launching a macOS path…": @"Запуск пути macOS…",
            @"Requesting a display refresh…": @"Запрос обновления экрана…",
            @"Safety protection triggered": @"Сработала защита",
            @"Generating startup configuration…": @"Создание конфигурации запуска…",
            @"Cleaning previous service state…": @"Очистка старого состояния служб…",
            @"Preparing the application runtime…": @"Подготовка среды приложений…",
            @"Validating graphics startup requirements…": @"Проверка графических условий запуска…",
            @"Starting safety protection…": @"Запуск защиты…",
            @"Starting macOS system services…": @"Запуск системных служб macOS…",
            @"Waiting for the first frame…": @"Ожидание первого кадра…",
            @"macOS workspace is ready": @"Рабочее пространство macOS готово",
            @"MacWS Workspace": @"Рабочее пространство MacWS",
            @"MacWS Window": @"Окно MacWS",
            @"Launch": @"Запустить",
            @"Stop": @"Остановить",
            @"Error": @"Ошибка",
            @"Retry": @"Повторить",
            @"Cancel": @"Отмена",
            @"Open": @"Открыть",
            @"Close": @"Закрыть",
            @"Settings": @"Настройки",
            @"Fullscreen": @"Полный экран",
            @"Window": @"Окно",
        };
    });
    return map[text] ?: text;
}

static void MWTranslateTree(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        label.text = MWTranslate(label.text);
        label.accessibilityLabel = MWTranslate(label.accessibilityLabel);
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        if (title.length) [button setTitle:MWTranslate(title) forState:UIControlStateNormal];
        button.accessibilityLabel = MWTranslate(button.accessibilityLabel);
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        field.placeholder = MWTranslate(field.placeholder);
        field.accessibilityLabel = MWTranslate(field.accessibilityLabel);
    }
    for (UIView *child in view.subviews) MWTranslateTree(child);
}

static NSData *MWSendCommand(NSString *command) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = MWRussianSocket.UTF8String;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        close(fd);
        return nil;
    }
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return nil;
    }
    NSData *payload = [[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, payload.bytes, payload.length, 0);
    uint8_t buffer[4096];
    ssize_t n = recv(fd, buffer, sizeof(buffer) - 1, 0);
    close(fd);
    if (n <= 0) return nil;
    buffer[n] = 0;
    return [NSData dataWithBytes:buffer length:(NSUInteger)n];
}

static NSString *MWCurrentStatus(void) {
    NSData *reply = MWSendCommand(@"status");
    if (!reply.length) return @"Служба настройки недоступна";
    NSString *s = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
    return s.length ? s : @"Неизвестное состояние";
}

static UIViewController *MWFindController(UIViewController *root) {
    if (!root) return nil;
    NSString *name = NSStringFromClass(root.class);
    if ([name isEqualToString:@"MacWSViewController"] || [name containsString:@"MacWSViewController"]) return root;
    for (UIViewController *child in root.children) {
        UIViewController *found = MWFindController(child);
        if (found) return found;
    }
    if (root.presentedViewController) return MWFindController(root.presentedViewController);
    return nil;
}

@interface MWRussianSetupController : NSObject
@property(nonatomic, weak) UIViewController *host;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *setupButton;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation MWRussianSetupController

- (void)installInto:(UIViewController *)host {
    self.host = host;
    UIView *root = host.view;
    if (!root || [root viewWithTag:0x4D575253]) return;

    MWTranslateTree(root);

    self.panel = [[UIView alloc] initWithFrame:CGRectZero];
    self.panel.tag = 0x4D575253;
    self.panel.translatesAutoresizingMaskIntoConstraints = NO;
    self.panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.92];
    self.panel.layer.cornerRadius = 16.0;
    self.panel.layer.masksToBounds = YES;

    self.setupButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.setupButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.setupButton.backgroundColor = [UIColor colorWithRed:0.16 green:0.48 blue:0.92 alpha:1.0];
    [self.setupButton setTitle:@"не еби мне мозги, просто всё сделай сам" forState:UIControlStateNormal];
    [self.setupButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.setupButton.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    self.setupButton.titleLabel.numberOfLines = 2;
    self.setupButton.layer.cornerRadius = 12.0;
    self.setupButton.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
    [self.setupButton addTarget:self action:@selector(setupTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchButton.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    [self.launchButton setTitle:@"Запустить macOS" forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    self.launchButton.layer.cornerRadius = 12.0;
    [self.launchButton addTarget:self action:@selector(launchTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Готово. Нажмите большую кнопку для полной автоматической настройки.";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:12.0];
    self.statusLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.setupButton, self.launchButton, self.statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panel addSubview:stack];
    [root addSubview:self.panel];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.panel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10.0],
        [self.panel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10.0],
        [self.panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10.0],
        [stack.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor constant:10.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor constant:-10.0],
        [stack.topAnchor constraintEqualToAnchor:self.panel.topAnchor constant:10.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor constant:-10.0],
        [self.setupButton.heightAnchor constraintGreaterThanOrEqualToConstant:50.0],
        [self.launchButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [self refresh:nil];
}

- (void)refresh:(NSTimer *)timer {
    (void)timer;
    NSString *status = MWCurrentStatus();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.host) return;
        self.statusLabel.text = [NSString stringWithFormat:@"Статус: %@", status];
    });
}

- (void)setupTapped:(id)sender {
    (void)sender;
    self.setupButton.enabled = NO;
    self.launchButton.enabled = NO;
    self.statusLabel.text = @"Запуск полной автоматической установки…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *reply = MWSendCommand(@"setup");
        NSString *text = reply.length ? [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] : @"Не удалось связаться со службой настройки.";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = text;
            self.setupButton.enabled = YES;
            self.launchButton.enabled = YES;
        });
    });
}

- (void)launchTapped:(id)sender {
    (void)sender;
    self.launchButton.enabled = NO;
    self.statusLabel.text = @"Запуск macOS…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *reply = MWSendCommand(@"launch");
        NSString *text = reply.length ? [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] : @"Не удалось связаться со службой запуска.";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = text;
            self.launchButton.enabled = YES;
        });
    });
}

@end

static MWRussianSetupController *MWSharedSetupController;

static void MWInstallRussianUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        } else {
            [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
        }
        for (UIWindow *window in windows) {
            UIViewController *controller = MWFindController(window.rootViewController);
            if (!controller) continue;
            if (!MWSharedSetupController) MWSharedSetupController = [MWRussianSetupController new];
            [MWSharedSetupController installInto:controller];
            MWTranslateTree(controller.view);
        }
    });
}

__attribute__((constructor)) static void MWRussianSetupConstructor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MWInstallRussianUI();
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
            MWInstallRussianUI();
        }];
    });
}
