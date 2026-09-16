// entry/src/main/ets/common/DocViewer.ets
// 内置文档浏览器：整页覆盖层 + Web 组件，用于在应用内展示《隐私政策》《用户服务协议》。
// 为什么不用系统浏览器 / 弹窗：
//   1) 用户要求"点了就在应用里看，随手可关"，不跳出应用；
//   2) 本环境实测系统弹层（CustomDialogController / bindSheet）由异步流程驱动时不可靠，
//      而"必须有"的界面一律用整页覆盖层（与首启同意门禁 consentGate 同一套路）。
// 宿主用法：@State showDoc / docTitle / docUrl，根 Stack 最后一层 if (this.showDoc) { DocViewer({...}) }。
import { webview } from '@kit.ArkWeb';

@Component
export struct DocViewer {
  /** 标题栏文案（如"隐私政策"） */
  title: string = '';
  /** 文档地址（http / https） */
  url: string = '';
  /** 点击"关闭"时回调 —— 由宿主把 showDoc 置回 false */
  onClose: () => void = () => {};

  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    Column() {
      // 标题栏：左标题、右关闭（点击即退出，符合"随手关掉"的预期）
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('✕')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 4 })
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.shadow_color') } })

      // 文档正文：交给系统 Web 内核渲染（页面自身已适配移动端与深色模式）
      Web({ src: this.url, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .domStorageAccess(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 沉浸式：背景延伸到状态栏/导航条区域（只扩绘制，Web 与标题栏仍在安全区内）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
