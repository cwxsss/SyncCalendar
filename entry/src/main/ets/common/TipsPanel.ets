// entry/src/main/ets/common/TipsPanel.ets
// 首启功能引导卡片：底部弹出，Swiper 三页，左下"上一步" / 右下"下一步"（末页变"开始使用"）。
// 数据源 items 中图标为 media 下的 SVG（tip_security / tip_calendar / tip_mute）。
// 同时被首页（首启自动弹出）与设置页（手动 revisar）复用。
import { AppSettings } from './AppSettings';

/** 单张引导卡的数据 */
interface TipItem {
  icon: Resource;   // app.media 下的 SVG 矢量图标
  title: string;
  desc: string;
}

@Component
export struct TipsPanel {
  @State current: number = 0;
  private controller: SwiperController = new SwiperController();
  /** 末页点击"开始使用"时回调（由宿主关闭弹层） */
  onClose: () => void = () => {};

  private items: TipItem[] = [
    {
      icon: $r('app.media.tip_security'),
      title: '你的数据安全，由你做主',
      desc: '我们不在服务器保存任何日程或账号数据。日历只在你的设备与你自己填写的 CalDAV 服务器之间同步，' +
        '全程加密保存。开源、无后门，数据始终属于你。'
    },
    {
      icon: $r('app.media.tip_calendar'),
      title: '系统日历，也能一起管',
      desc: '手机系统日历可与 CalDAV 日历混合显示在同一时间轴，也能把系统日历本通过 CalDAV 同步备份，' +
        '一处编辑、处处更新。到「设置 → 混合显示系统日历」开启并授权即可。'
    },
    {
      icon: $r('app.media.tip_mute'),
      title: '只读与静音，自由设置',
      desc: '每个日历本都能单独设为只读或静音：只读日历不出现在新建选择中、避免误改；' +
        '静音日历照常显示，但不再推送提醒。'
    }
  ];

  build() {
    Column({ space: 0 }) {
      Swiper(this.controller) {
        ForEach(this.items, (item: TipItem, idx: number) => {
          Column({ space: 16 }) {
            Image(item.icon)
              .width(140)
              .height(140)
              .objectFit(ImageFit.Contain)
              .margin({ top: 24, bottom: 8 })
            Text(item.title)
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ bottom: 8 })
            Text(item.desc)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .lineHeight(22)
              .padding({ left: 28, right: 28 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }, (item: TipItem, idx: number) => `tip_${idx}`)
      }
      .width('100%')
      .layoutWeight(1)
      .indicator(new DotIndicator().selectedColor('#007DFF').color('#CFD8E3').itemWidth(6).itemHeight(6))
      .loop(false)
      .onChange((index: number): void => {
        this.current = index;
      })

      // 底部导航：左下角"上一步" / 右下角"下一步"（末页变"开始使用"）
      Row() {
        Button('上一步')
          .fontSize(15)
          .width(96)
          .height(42)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor(this.current === 0 ? $r('app.color.text_hint') : $r('app.color.text_primary'))
          .enabled(this.current > 0)
          .onClick(() => {
            if (this.current > 0) {
              this.current -= 1;
              this.controller.changeIndex(this.current, false);
            }
          })
        Button(this.current >= this.items.length - 1 ? '开始使用' : '下一步')
          .fontSize(15)
          .width(96)
          .height(42)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.button_text'))
          .onClick(() => {
            if (this.current >= this.items.length - 1) {
              this.onClose();
            } else {
              this.current += 1;
              this.controller.changeIndex(this.current, false);
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: 20, right: 20, top: 12, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
