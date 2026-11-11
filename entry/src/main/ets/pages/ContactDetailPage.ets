// entry/src/main/ets/pages/ContactDetailPage.ets
// 联系人详情：查看 + 编辑（姓名/公司/电话/邮箱/备注）+ 删除 + 推送回远端
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { relationalStore } from '@kit.ArkData';
import { ContactDb, ContactRow } from '../common/ContactDb';
import { ContactService } from '../common/ContactService';
import { VCardPhone, VCardEmail, VCardContact, VCardUtil } from '../common/VCardUtil';
import { LogUtil } from '../common/LogUtil';

@Entry
@Component
struct ContactDetailPage {
  @State rowId: number = 0;
  @State displayName: string = '';
  @State familyName: string = '';
  @State givenName: string = '';
  @State org: string = '';
  @State title: string = '';
  @State note: string = '';
  /** 电话/邮箱用「一行一个」的文本编辑，简单可靠，不用动态列表 */
  @State phonesText: string = '';
  @State emailsText: string = '';
  @State editing: boolean = false;
  @State saving: boolean = false;
  @State statusMsg: string = '';
  @State loaded: boolean = false;

  aboutToAppear(): Promise<void> {
    return this.load();
  }

  private async load(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    LogUtil.init(ctx);
    const id: number | undefined = AppStorage.get<number>('pendingContactId');
    if (id === undefined || id === 0) {
      this.statusMsg = '缺少联系人 ID';
      return;
    }
    this.rowId = id;
    const row: ContactRow | null = await ContactDb.findById(ctx, id);
    if (row === null) {
      this.statusMsg = '联系人不存在（可能已被删除）';
      return;
    }
    this.displayName = row.displayName;
    this.org = row.org;
    this.title = row.title;
    this.note = row.note;
    this.phonesText = this.jsonToLines(row.phonesJson);
    this.emailsText = this.jsonToLines(row.emailsJson);
    // 姓名分段（姓/名）统一走 VCardUtil 解析，别再自己写正则。
    // 🔴 2026-11-11 踩过：自制 /^N:(.*)$/m 有两个坑 ——
    //   ① 区分大小写，行首带 \r 时 ^ 对不上；
    //   ② 服务端返回的长行是**折行**的，正则只拿到第一段。
    //    表现为"姓/名 一直显示 —"，而 FN 正常，很难怀疑到正则。
    const parsed: VCardContact | null = VCardUtil.parse(row.raw, row.href, row.etag);
    if (parsed !== null) {
      this.familyName = parsed.familyName;
      this.givenName = parsed.givenName;
    }
    this.loaded = true;
  }

  private jsonToLines(json: string): string {
    if (json === '') {
      return '';
    }
    try {
      const arr = JSON.parse(json) as string[];
      return arr.join('\n');
    } catch (err) {
      return '';
    }
  }

  private linesToList(text: string): string[] {
    return text.split('\n')
      .map((s: string): string => s.trim())
      .filter((s: string): boolean => s !== '');
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    if (this.displayName.trim() === '') {
      this.statusMsg = '姓名不能为空';
      return;
    }
    this.saving = true;
    this.statusMsg = '正在保存…';
    try {
      const row: ContactRow | null = await ContactDb.findById(ctx, this.rowId);
      if (row === null) {
        this.statusMsg = '联系人不存在';
        this.saving = false;
        return;
      }
      // 更新内存模型并写回库
      const phones: string[] = this.linesToList(this.phonesText);
      const emails: string[] = this.linesToList(this.emailsText);
      const phonesJson: string = JSON.stringify(phones);
      const emailsJson: string = JSON.stringify(emails);

      const store = await ContactDb.getDb(ctx);
      const values: relationalStore.ValuesBucket = {
        'display_name': this.displayName.trim(),
        'org': this.org.trim(),
        'title': this.title.trim(),
        'note': this.note,
        'phones_json': phonesJson,
        'emails_json': emailsJson,
        'dirty': 1
      };
      const pred = new relationalStore.RdbPredicates('contacts');
      pred.equalTo('id', this.rowId);
      await store.update(values, pred);

      // 推送回远端
      const ok: boolean = await ContactService.pushContact(ctx, this.rowId);
      this.editing = false;
      if (ok) {
        this.statusMsg = '已保存并同步到服务器';
        this.getUIContext().getPromptAction().showToast({ message: '已保存' });
      } else {
        this.statusMsg = '已在本地保存，但推送到服务器失败（稍后重试同步）';
      }
      LogUtil.write(`联系人「${this.displayName}」保存，推送=${ok}`);
    } catch (err) {
      const e = err as BusinessError;
      this.statusMsg = `保存失败：${e.message}`;
      LogUtil.write(`保存联系人失败：${e.message}`);
    }
    this.saving = false;
  }

  private async remove(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除联系人',
      message: `确定删除「${this.displayName}」？该操作会同时从服务器删除。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: async (): Promise<void> => {
          await ContactDb.markDeleted(ctx, this.rowId);
          const ok: boolean = await ContactService.pushContact(ctx, this.rowId);
          if (ok) {
            this.getUIContext().getPromptAction().showToast({ message: '已删除' });
            router.back();
          } else {
            this.statusMsg = '本地已删除，但服务器删除失败（稍后重试同步）';
          }
        }
      }
    });
  }

  @Builder
  fieldRow(label: string, value: string, onChange: (v: string) => void) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      if (this.editing) {
        TextInput({ text: value })
          .height(42)
          .fontSize(15)
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange(onChange)
      } else {
        Text(value === '' ? '—' : value)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  multiFieldRow(label: string, value: string, onChange: (v: string) => void, hint: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      if (this.editing) {
        TextArea({ text: value, placeholder: hint })
          .height(label === '备注' ? 90 : 70)
          .fontSize(15)
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onChange(onChange)
      } else {
        Text(value === '' ? '—' : value)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 6 }) {
        Text('←')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
        Text('返回')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
        Blank()
        if (this.loaded) {
          Text(this.editing ? '取消' : '编辑')
            .fontSize(15)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              this.editing = !this.editing;
              if (!this.editing) {
                this.load();
              }
            })
        }
      }
      .width('100%')

      if (!this.loaded) {
        Text(this.statusMsg === '' ? '加载中…' : this.statusMsg)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      } else {
        Scroll() {
          Column({ space: 14 }) {
            // 头部：头像 + 名字
            Row({ space: 14 }) {
              Text(this.displayName.trim() === '' ? '#' : this.displayName.trim().charAt(0))
                .width(56)
                .height(56)
                .borderRadius(28)
                .backgroundColor($r('app.color.brand'))
                .fontColor(Color.White)
                .fontSize(24)
                .textAlign(TextAlign.Center)
              Text(this.displayName)
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
            }
            .width('100%')

            Column({ space: 12 }) {
              this.fieldRow('姓名', this.displayName, (v: string) => {
                this.displayName = v;
              })
              this.fieldRow('姓', this.familyName, (v: string) => {
                this.familyName = v;
              })
              this.fieldRow('名', this.givenName, (v: string) => {
                this.givenName = v;
              })
              this.fieldRow('公司', this.org, (v: string) => {
                this.org = v;
              })
              this.fieldRow('职位', this.title, (v: string) => {
                this.title = v;
              })
            }
            .width('100%')
            .padding(14)
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.shadow_color') })

            Column({ space: 12 }) {
              this.multiFieldRow('电话', this.phonesText, (v: string) => {
                this.phonesText = v;
              }, '每行一个号码')
              this.multiFieldRow('邮箱', this.emailsText, (v: string) => {
                this.emailsText = v;
              }, '每行一个邮箱')
              this.multiFieldRow('备注', this.note, (v: string) => {
                this.note = v;
              }, '备注')
            }
            .width('100%')
            .padding(14)
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.shadow_color') })

            if (this.statusMsg !== '') {
              Text(this.statusMsg)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding(10)
                .borderRadius(10)
                .backgroundColor($r('app.color.card_bg'))
            }

            if (this.editing) {
              Button(this.saving ? '保存中…' : '保存')
                .width('100%')
                .height(46)
                .fontSize(16)
                .enabled(!this.saving)
                .onClick(() => {
                  this.save();
                })
            } else {
              Button('删除联系人')
                .width('100%')
                .height(46)
                .fontSize(16)
                .fontColor($r('app.color.error'))
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 1, color: $r('app.color.error'), radius: 10 })
                .onClick(() => {
                  this.remove();
                })
            }
          }
          .width('100%')
          .padding({ bottom: 30 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
    .backgroundColor($r('app.color.page_bg'))
  }
}