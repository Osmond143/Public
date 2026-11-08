// ProbeViewController.m
#import "ProbeViewController.h"
#import "ProbeClient.h"
#include "DumpOffsets.h"
#include <unistd.h>

@interface ProbeViewController ()
@property (nonatomic, strong) UITextView *log;
@property (nonatomic, strong) UIButton   *runBtn;
@property (nonatomic, strong) UILabel    *status;
@end

@implementation ProbeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];

    CGFloat W = self.view.bounds.size.width;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, W - 32, 30)];
    title.text = @"VEsp Probe  ·  DarkSword KRW";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    [self.view addSubview:title];

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(16, 92, W - 32, 22)];
    self.status.text = @"就绪";
    self.status.textColor = [UIColor lightGrayColor];
    self.status.font = [UIFont systemFontOfSize:12];
    [self.view addSubview:self.status];

    self.runBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runBtn.frame = CGRectMake(16, 122, W - 32, 46);
    [self.runBtn setTitle:@"运行探测" forState:UIControlStateNormal];
    [self.runBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.runBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.runBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.45 blue:0.95 alpha:1.0];
    self.runBtn.layer.cornerRadius = 10;
    [self.runBtn addTarget:self action:@selector(onRun) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.runBtn];

    CGFloat logY = 180;
    self.log = [[UITextView alloc] initWithFrame:CGRectMake(12, logY, W - 24,
                                                            self.view.bounds.size.height - logY - 20)];
    self.log.backgroundColor = [UIColor colorWithWhite:0.02 alpha:1.0];
    self.log.textColor = [UIColor colorWithRed:0.6 green:0.95 blue:0.6 alpha:1.0];
    self.log.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.log.editable = NO;
    self.log.text = @"点上面的按钮开始\n";
    [self.view addSubview:self.log];
}

- (void)append:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.log.text = [self.log.text stringByAppendingFormat:@"%@\n", s];
        NSRange r = NSMakeRange(self.log.text.length, 0);
        [self.log scrollRangeToVisible:r];
    });
    NSLog(@"[vesp] %@", s);
}

- (void)onRun {
    self.runBtn.enabled = NO;
    self.log.text = @"";
    [self append:@"=== 开始 ==="];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [self doProbe];
        dispatch_async(dispatch_get_main_queue(), ^{ self.runBtn.enabled = YES; });
    });
}

- (void)doProbe {
    ProbeClient *c = [ProbeClient shared];

    [self append:[NSString stringWithFormat:@"uid=%d  pid=%d", getuid(), getpid()]];
    [self append:[NSString stringWithFormat:@"设备: %@  %@",
                  UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion]];

    // 1) 枚举候选
    [self append:@"\n--- 候选枚举 ---"];
    NSArray *cands = [c enumerateCandidates];
    if (cands.count == 0) {
        [self append:@"(没有找到任何 dskrw 痕迹)"];
    } else {
        for (NSDictionary *d in cands) {
            [self append:[NSString stringWithFormat:@"  [%@] %@  %@",
                          d[@"kind"], d[@"name"],
                          d[@"value"] ?: d[@"base"] ?: @""]];
        }
    }

    // 2) 试连接（服务名和 token 等 M1 挖出来再填）
    [self append:@"\n--- 尝试连接 ---"];
    // TODO(M1): 填真实服务名与 token
    [c connectService:@"com.okdemo.dskrw.rw" token:nil];
    [self append:[NSString stringWithFormat:@"status=%ld  %@",
                  (long)c.status, c.lastError ?: @""]];

    if (c.status == KRWStatusReady) {
        [self append:@"\n--- 逐偏移探测 ---"];
        dump_offsets_run(krw_read_bridge);
    }

    [self append:@"\n=== 结束 ==="];
}

@end
