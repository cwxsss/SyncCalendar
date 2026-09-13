import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackgroundSyncService } from '../common/BackgroundSyncService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 后台同步：注册延迟任务兜底 + 按设置恢复长时任务
    BackgroundSyncService.initOnLaunch(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
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