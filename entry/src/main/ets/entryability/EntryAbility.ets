import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackgroundSyncService } from '../common/BackgroundSyncService';
import { LogUtil } from '../common/LogUtil';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 文件日志初始化：所有页面的同步日志统一写入 filesDir/sync.log
    LogUtil.init(this.context);
    LogUtil.write('---- App 启动 ----');
    // 后台同步：注册延迟任务兜底 + 按设置恢复长时任务
    BackgroundSyncService.initOnLaunch(this.context);
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
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 沉浸式配色：状态栏/导航条与页面背景同色（app.color.page_bg = #F1F3F5），
      // 消除顶部通知栏和底部的白色条
      windowStage.getMainWindow((werr: BusinessError, win: window.Window) => {
        if (werr.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to get main window. Cause: %{public}s', JSON.stringify(werr));
          return;
        }
        try {
          win.setWindowSystemBarProperties({
            statusBarColor: '#F1F3F5',
            statusBarContentColor: '#182431',
            navigationBarColor: '#F1F3F5',
            navigationBarContentColor: '#182431'
          });
          // 鸿蒙 NEXT 导航条背景跟随窗口背景色：设为页面背景灰，消除底部白条
          win.setWindowBackgroundColor('#F1F3F5');
        } catch (barErr) {
          hilog.error(DOMAIN, 'testTag', 'Failed to set system bar properties. Cause: %{public}s',
            JSON.stringify(barErr));
        }
      });
    });
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}