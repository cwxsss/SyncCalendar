import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration, EnvironmentCallback } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BackgroundSyncService } from '../common/BackgroundSyncService';
import { NetworkSyncWatcher } from '../common/NetworkSyncWatcher';
import { BackgroundSyncRunner } from '../common/BackgroundSyncRunner';
import { LogUtil } from '../common/LogUtil';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 日志初始化：发行版只输出 console（不再落盘 sync.log），同时清理历史遗留调试文件
    LogUtil.init(this.context);
    LogUtil.write('---- App 启动 ----');
    // 后台同步：注册延迟任务兜底（2 小时）＋ 网络恢复补同步监听
    // ⚠️ 不再申请"长时任务"：dataTransfer 类型有 10 分钟无进度即被取消的一致性校验，
    //    日历同步不符合该语义、必被取消（详见 BackgroundSyncService 顶部注释）。
    BackgroundSyncService.initOnLaunch(this.context);
    NetworkSyncWatcher.start(this.context);
    // 服务卡片"添加"按钮跳转：把 widgetAction=add 透传给主页面（在 AppStorage 中暂存）
    this.handleWidgetParam(want);
    // ⚠️ 这里**不再申请任何权限**（含通知权限）。
    // 依据《审核指南》7.17：应用不得在用户未主动点击对应功能时提前弹窗申请权限。
    // 通知权限改为在用户主动操作时申请：
    //   ① 保存带提醒的日程（EventEditPage）② 开启「后台持续同步」（SettingsPage）
    //   ③ 设置页「通知权限」→「去开启通知」按钮
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  /** 卡片"添加"按钮已在后台运行时再次点击：同样把 widgetAction 透传给主页面 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleWidgetParam(want);
  }

  /** 读取卡片深链参数：widgetAction=add 拉起新建日程；openDate 定位到卡片当前显示日 */
  private handleWidgetParam(want: Want): void {
    const params = want.parameters;
    if (params !== undefined) {
      const raw = params['widgetAction'];
      if (typeof raw === 'string' && raw === 'add') {
        AppStorage.setOrCreate<string>('widgetAction', 'add');
        LogUtil.write('卡片添加入口：已设置 widgetAction=add');
      }
      // 卡片点击进入日历时，定位到卡片当前显示的那一天（用户可能已翻到其他日期）
      const od = params['openDate'];
      let odMs: number = 0;
      if (typeof od === 'number') {
        odMs = od;
      } else if (typeof od === 'string' && od.length > 0) {
        const parsed = parseInt(od, 10);
        if (!isNaN(parsed)) {
          odMs = parsed;
        }
      }
      // 合法性校验：13 位毫秒时间戳若按 int32 传递会溢出成 2147483647 等小值 →
      // 只接受 [2000-01-01, 2100-01-01] 区间，避免把日历定位到 1970
      if (odMs >= 946684800000 && odMs <= 4102444800000) {
        AppStorage.setOrCreate<number>('widgetOpenDate', odMs);
        LogUtil.write(`卡片进入日历：定位到显示日 ${odMs}`);
      } else if (odMs > 0) {
        LogUtil.write(`卡片 openDate 非法（疑似 int32 溢出）：${odMs}，忽略`);
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    // ① 先把应用固定为「跟随系统」深浅色。必须在取窗口/刷系统栏之前调用，
    //    否则会读到尚未更新到深色的色彩配置（曾导致深色下状态栏仍是浅灰）。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // ② 沉浸式配色：状态栏/导航条背景**透明**，透出「主题化」的窗口底色，
    //    消除顶部通知栏与底部灰条；前景（时间/图标）颜色按实际底色亮度取反。
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.mainWindow = win;
      this.applySystemBars(win);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to apply immersive bars. Cause: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // ③ 系统深浅色切换时重刷配色。用 applicationContext 的 environment 回调，
    //    它比 UIAbility.onConfigurationUpdate 更可靠（后者在部分场景下不回调，
    //    会出现"页面已变深色但状态栏/底部仍是浅灰"的现象）。
    try {
      const cb: EnvironmentCallback = {
        onConfigurationUpdated: (config: Configuration): void => {
          if (this.mainWindow !== undefined) {
            this.applySystemBars(this.mainWindow);
          }
        },
        onMemoryLevel: (level: AbilityConstant.MemoryLevel): void => {
        }
      };
      this.context.getApplicationContext().on('environment', cb);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to watch environment. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /** 主窗口引用：系统深浅色切换时需要重新刷状态栏/导航栏配色 */
  private mainWindow?: window.Window;

  /** 当前是否处于系统深色模式（兜底用） */
  private isDarkMode(): boolean {
    try {
      return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (err) {
      return false;
    }
  }

  /**
   * 取当前主题下 app.color.page_bg 的真实取值（经 dark/ 限定符解析）：
   * 浅色 #F1F3F5 ／ 深色 #000000。以"资源系统实际解析出的颜色"为准，
   * 这样才能与页面真正渲染出来的背景色一致，不受 config 更新时机影响。
   */
  private themePageBg(): string {
    try {
      const c: number = this.context.resourceManager.getColorSync($r('app.color.page_bg').id) >>> 0;
      return '#' + c.toString(16).padStart(8, '0');
    } catch (err) {
      return this.isDarkMode() ? '#000000' : '#F1F3F5';
    }
  }

  /** 背景是深色时需要浅色前景，反之用深色前景 */
  private isDarkBg(bg: string): boolean {
    const s: string = bg.startsWith('#') ? bg.substring(1) : bg;
    if (s.length < 6) {
      return this.isDarkMode();
    }
    const off: number = s.length >= 8 ? 2 : 0;
    const r: number = parseInt(s.substring(off, off + 2), 16);
    const g: number = parseInt(s.substring(off + 2, off + 4), 16);
    const b: number = parseInt(s.substring(off + 4, off + 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return this.isDarkMode();
    }
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128;
  }

  /**
   * 按当前主题设置状态栏/导航条与窗口底色。
   * 背景取 0x00000000（全透明）——官方推荐的背景沉浸方案：系统栏透明，
   * 透传应用自身背景，因此底色天然跟随深浅色，不会再出现恒定灰条。
   */
  private applySystemBars(win: window.Window): void {
    const bgColor: string = this.themePageBg();
    const fgColor: string = this.isDarkBg(bgColor) ? '#FFFFFF' : '#182431';
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: fgColor,
        navigationBarColor: '#00000000',
        navigationBarContentColor: fgColor
      });
      // 窗口底色＝页面背景色，供透明的状态栏/导航条透出
      win.setWindowBackgroundColor(bgColor);
    } catch (barErr) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set system bar properties. Cause: %{public}s',
        JSON.stringify(barErr));
    }
  }

  /** 兜底：部分设备/场景只回调 UIAbility.onConfigurationUpdate */
  onConfigurationUpdate(): void {
    if (this.mainWindow !== undefined) {
      this.applySystemBars(this.mainWindow);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // ⭐ 回到前台：① 归还短时任务配额 ② 立刻补同步一次（用户真正要看时数据必须最新）
    BackgroundSyncService.cancelTransientSync();
    BackgroundSyncRunner.runOnce(this.context, 'foreground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // ⭐ 退到后台：申请短时任务，兜住"退后台后那一次"同步能跑完
    //    （必须在退后台 5 秒内申请；单次最长 3 分钟，单日配额 10 分钟）
    BackgroundSyncService.requestTransientSync('正在同步日历数据');
  }
}