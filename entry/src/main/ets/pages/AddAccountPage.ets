// entry/src/main/ets/pages/AddAccountPage.ets
// 添加账号第一页：URL / 用户名 / 密码 → 连接（凭据经 AppStorage 传给日历本选择页）
import { http } from '@kit.NetworkKit';
import { router } from '@kit.ArkUI';
import { buffer } from '@kit.ArkTS';
import url from '@ohos.url';
import { BusinessError } from '@kit.BasicServicesKit';
import { TYPE_CALDAV, TYPE_CARDDAV, TYPE_WEBDAV } from '../common/AccountStore';

@Entry
@Component
struct AddAccountPage {
  @State serverUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State isLoading: boolean = false;
  @State statusMsg: string = '';
  @State statusOk: boolean = false;
  @State typeLabel: string = 'CalDAV';
  private accountType: string = TYPE_CALDAV;

  aboutToAppear(): void {
    const t: string | undefined = AppStorage.get<string>('pendingAccountType');
    this.accountType = (t === undefined || t === '') ? TYPE_CALDAV : t;
    if (this.accountType === TYPE_CARDDAV) {
      this.typeLabel = 'CardDAV';
    } else if (this.accountType === TYPE_WEBDAV) {
      this.typeLabel = 'WebDAV';
    } else {
      this.typeLabel = 'CalDAV';
    }
  }

  private normalizeUrl(): string | null {
    let rawUrl: string = this.serverUrl.trim();
    if (rawUrl === '') {
      return null;
    }
    if (!rawUrl.startsWith('http://') && !rawUrl.startsWith('https://')) {
      rawUrl = 'https://' + rawUrl;
    }
    const hostPattern: RegExp =
      /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$|^\d{1,3}(\.\d{1,3}){3}$|^\[[0-9A-Fa-f:]+\]$|^localhost$/;
    try {
      const parsed = url.URL.parseURL(rawUrl);
      const hostname: string = parsed.hostname !== '' ? parsed.hostname : parsed.host;
      if (hostname !== '' && hostPattern.test(hostname)) {
        return rawUrl;
      }
      this.statusMsg = `URL 主机名无效：${rawUrl}`;
      this.statusOk = false;
      return null;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`URL 解析异常(${e.code})，使用正则兜底: ${e.message}`);
      const fallbackPattern: RegExp =
        /^https?:\/\/[^\s/:?#]+(:\d{1,5})?([/?#][^\s]*)?$/;
      if (fallbackPattern.test(rawUrl)) {
        return rawUrl;
      }
      this.statusMsg = `URL 解析失败：${e.message}`;
      this.statusOk = false;
      return null;
    }
  }

  private encodeBasicAuth(): string {
    try {
      return buffer.from(`${this.username}:${this.password}`).toString('base64');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`Base64 编码失败: ${e.message}`);
      return '';
    }
  }

  private async sendOnce(serverUrl: string, method: http.RequestMethod, authHeader: string): Promise<number> {
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(serverUrl, {
        method: method,
        header: {
          'Authorization': authHeader,
          'Accept': '*/*',
          'User-Agent': 'SyncCalendar/1.0'
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });
      return resp.responseCode;
    } finally {
      httpRequest.destroy();
    }
  }

  private async probeServer(serverUrl: string): Promise<boolean> {
    const token: string = this.encodeBasicAuth();
    if (token === '') {
      this.statusMsg = '凭据编码失败：请在真机或模拟器上运行';
      this.statusOk = false;
      return false;
    }
    const authHeader: string = 'Basic ' + token;
    try {
      let code: number = await this.sendOnce(serverUrl, http.RequestMethod.OPTIONS, authHeader);
      if (code === 401) {
        code = await this.sendOnce(serverUrl, http.RequestMethod.GET, authHeader);
      }
      if (code === 401) {
        this.statusMsg = '服务器拒绝凭据(401)，请检查用户名密码';
        this.statusOk = false;
        return false;
      }
      if (code >= 200 && code < 500) {
        this.statusMsg = '服务器连接成功';
        this.statusOk = true;
        return true;
      }
      this.statusMsg = `服务器返回异常状态码：${code}`;
      this.statusOk = false;
      return false;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`连接失败: ${e.code} - ${e.message}`);
      this.statusMsg = `无法连接服务器：${e.message}`;
      this.statusOk = false;
      return false;
    }
  }

  private async onConnectAndSave(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    const targetUrl: string | null = this.normalizeUrl();
    if (targetUrl === null) {
      if (this.statusMsg === '' || this.statusMsg === '正在连接服务器…' || this.statusOk) {
        this.statusMsg = '请输入有效的服务器地址';
      }
      this.statusOk = false;
      return;
    }
    if (!this.username.trim()) {
      this.statusMsg = '请输入用户名';
      this.statusOk = false;
      return;
    }
    if (!this.password) {
      this.statusMsg = '请输入密码';
      this.statusOk = false;
      return;
    }

    // 明文 HTTP 属于"已知不安全"的传输方式：Basic 凭据（用户名/密码）会以未加密形式
    // 在网络上传输，可被同网络中间人直接读取。
    // 不直接拒绝（局域网自建 NAS/测试环境常用 http），但必须让用户明确知情并二次确认，
    // 避免用户在不知情下把凭据发到明文信道。
    if (targetUrl.startsWith('http://')) {
      this.getUIContext().showAlertDialog({
        title: '不安全连接',
        message: '该地址使用 http:// 明文连接，用户名与密码将以未加密方式在网络中传输，存在被窃听的风险。\n\n建议改用 https://。是否仍要继续？',
        autoCancel: true,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: '取消',
          action: (): void => {
            this.statusMsg = '已取消：建议改用 https:// 地址';
            this.statusOk = false;
          }
        },
        secondaryButton: {
          value: '仍要继续',
          fontColor: $r('app.color.error'),
          action: (): void => {
            this.doConnect(targetUrl);
          }
        }
      });
      return;
    }
    await this.doConnect(targetUrl);
  }

  /** 实际连接并（成功时）把凭据经 AppStorage 交给日历本选择页 */
  private async doConnect(targetUrl: string): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.statusMsg = '正在连接服务器…';
    this.statusOk = false;

    const ok: boolean = await this.probeServer(targetUrl);
    if (ok) {
      AppStorage.setOrCreate<string>('pendingDavUrl', targetUrl);
      AppStorage.setOrCreate<string>('pendingDavUsername', this.username.trim());
      AppStorage.setOrCreate<string>('pendingDavPassword', this.password);
      this.getUIContext().getPromptAction().showToast({ message: '连接成功' });
      router.pushUrl({ url: 'pages/CalendarListPage' });
    }
    this.isLoading = false;
  }

  build() {
    Column({ space: 24 }) {
      Row({ space: 6 }) {
        Text('←')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
        Text('返回')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      .onClick(() => {
        router.back();
      })

      Column({ space: 8 }) {
        Text(`添加${this.typeLabel}账号`)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('输入服务器账号信息')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 16 }) {
        this.formField('服务器地址', '例如：https://nas.example.com/caldav/', this.serverUrl,
          (value: string) => {
            this.serverUrl = value;
          }, false)
        this.formField('用户名', '请输入用户名', this.username,
          (value: string) => {
            this.username = value;
          }, false)
        this.formField('密码', '请输入密码', this.password,
          (value: string) => {
            this.password = value;
          }, true)
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.card_bg'))
      .shadow({ radius: 12, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 4 })

      Button() {
        Row({ space: 8 }) {
          if (this.isLoading) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.button_text'))
          }
          Text(this.isLoading ? '连接中…' : '连接并保存')
            .fontSize(17)
            .fontColor($r('app.color.button_text'))
            .fontWeight(FontWeight.Medium)
        }
      }
      .width('100%')
      .height(48)
      .borderRadius(24)
      .backgroundColor(this.isLoading ? $r('app.color.brand_disabled') : $r('app.color.brand'))
      .enabled(!this.isLoading)
      .onClick(() => {
        this.onConnectAndSave();
      })

      if (this.statusMsg) {
        Row({ space: 6 }) {
          Text(this.statusOk ? '✓' : '✕')
            .fontSize(14)
            .fontColor(this.statusOk ? $r('app.color.success') : $r('app.color.error'))
          Text(this.statusMsg)
            .fontSize(14)
            .fontColor(this.statusOk ? $r('app.color.success') : $r('app.color.error'))
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor(this.statusOk ? $r('app.color.success_bg') : $r('app.color.error_bg'))
      }

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 24 })
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  formField(label: string, placeholder: string, value: string,
    onChange: (value: string) => void, isPassword: boolean) {
    Column({ space: 8 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Medium)
      TextInput({ text: value, placeholder: placeholder })
        .type(isPassword ? InputType.Password : InputType.Normal)
        .showPasswordIcon(isPassword)
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(8)
        .onChange(onChange)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}