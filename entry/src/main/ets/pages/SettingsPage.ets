// entry/src/main/ets/pages/SettingsPage.ets
// 设置页：系统日历混合显示开关 + 自动同步间隔
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppSettings } from '../common/AppSettings';
import { LogUtil } from '../common/LogUtil';

const INTERVAL_OPTIONS: number[] = [1, 5, 15, 30, 60];

@Entry
@Component
struct SettingsPage {
  @State showSystem: boolean = true;
  @State intervalMinutes: number = 1;
  private context?: common.Context;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.context = ctx;
    LogUtil.init(ctx);
    AppSettings.getShowSystemCalendar(ctx).then((v: boolean): void => {
      this.showSystem = v;
    });
    AppSettings.getSyncIntervalMinutes(ctx).then((v: number): void => {
      this.intervalMinutes = v;
    });
  }

  private async saveShowSystem(value: boolean): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await AppSettings.setShowSystemCalendar(this.context, value);
    this.getUIContext().getPromptAction()
      .showToast({ message: value ? '已开启系统日历混合显示，返回首页生效' : '已关闭系统日历混合显示，返回首页生效' });
  }

  private async saveInterval(minutes: number): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await AppSettings.setSyncIntervalMinutes(this.context, minutes);
    AppStorage.setOrCreate('syncIntervalMinutes', minutes);
    this.getUIContext().getPromptAction()
      .showToast({ message: `自动同步间隔已设为 ${minutes} 分钟` });
  }

  private intervalLabel(minutes: number): string {
    return minutes >= 60 ? `${minutes / 60} 小时` : `${minutes} 分钟`;
  }

  build() {
    Column() {
      // 顶部
      Row({ space: 10 }) {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 系统日历混合显示
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('混合显示系统日历')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('关闭后只显示 DAV 账号的日程')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showSystem })
              .selectedColor($r('app.color.brand'))
              .onChange((isOn: boolean) => {
                if (isOn !== this.showSystem) {
                  this.showSystem = isOn;
                  this.saveShowSystem(isOn);
                }
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 自动同步间隔
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('自动同步间隔')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('应用打开期间按此间隔自动同步')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Select([{ value: '1 分钟' }, { value: '5 分钟' }, { value: '15 分钟' },
              { value: '30 分钟' }, { value: '1 小时' }] as SelectOption[])
              .selected(INTERVAL_OPTIONS.indexOf(this.intervalMinutes))
              .value(this.intervalLabel(this.intervalMinutes))
              .fontColor($r('app.color.text_primary'))
              .font({ size: 14 })
              .optionFont({ size: 14 })
              .selectedOptionFont({ size: 14 })
              .onSelect((index: number) => {
                if (index >= 0 && index < INTERVAL_OPTIONS.length) {
                  this.intervalMinutes = INTERVAL_OPTIONS[index];
                  this.saveInterval(INTERVAL_OPTIONS[index]);
                }
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
