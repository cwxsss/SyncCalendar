// entry/src/main/ets/entryformability/EntryFormAbility.ets
// 服务卡片 FormExtensionAbility：添加卡片时注入初始数据，定时/触发时更新
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import process from '@ohos.process';
import { CardDataService, CardData } from '../common/CardDataService';
import { BackgroundSyncRunner } from '../common/BackgroundSyncRunner';
import { LogUtil } from '../common/LogUtil';

export default class EntryFormAbility extends FormExtensionAbility {
  /** 当前进程 pid（取不到返回 -1）：用于判断卡片回调是否与主 App 同进程 */
  private static pidOf(): number {
    try {
      return process.pid;
    } catch (err) {
      return -1;
    }
  }

  /** 组装更新数据并推送到指定卡片 */
  private pushData(formId: string, dayOffset: number = 0, cardDays: number = 0): void {
    const days: number = cardDays > 0 ? cardDays : CardDataService.getCardDays(formId);
    CardDataService.buildCardData(this.context, dayOffset, days).then((data: CardData): void => {
      const binding: formBindingData.FormBindingData =
        formBindingData.createFormBindingData(data);
      formProvider.updateForm(formId, binding).catch((err: BusinessError): void => {
        LogUtil.write(`卡片 ${formId} 更新失败: ${err.message}`);
      });
      LogUtil.write(`卡片 ${formId} 数据已推送（跨度 ${data.cardDays} 天，偏移 ${dayOffset}）`);
    }).catch((err: BusinessError): void => {
      LogUtil.write(`卡片数据构建失败: ${err.message}`);
    });
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    LogUtil.init(this.context);
    let formId: string = '';
    if (want.parameters !== undefined) {
      const raw = want.parameters['ohos.extra.param.key.form_identity'];
      formId = typeof raw === 'string' ? raw : '';
    }
    LogUtil.write(`添加卡片: formId=${formId}`);
    // 先返回空壳初始数据，异步查库后推送真实数据
    if (formId !== '') {
      CardDataService.registerForm(this.context, formId);
      this.pushData(formId);
    }
    const initial = new CardData();
    return formBindingData.createFormBindingData(initial);
  }

  onUpdateForm(formId: string): void {
    LogUtil.init(this.context);
    LogUtil.write(`系统触发卡片更新: formId=${formId}（进程 pid=${EntryFormAbility.pidOf()}）`);
    CardDataService.registerForm(this.context, formId);
    // ⭐ ① 先用**本地缓存**立刻刷新卡片（几毫秒，不依赖网络）
    //    保留用户翻到的日期与选择的展示天数
    this.pushData(formId, CardDataService.getDayOffset(formId), CardDataService.getCardDays(formId));
    // ⭐ ② 再借这次系统刷新顺带跑一次后台同步（见 runOnceThrottledByCard：带节流、永不抛错）
    //    同步成功后再推一次，让卡片显示刚同步回来的最新数据。
    BackgroundSyncRunner.runOnceThrottledByCard(this.context).then((): void => {
      this.pushData(formId, CardDataService.getDayOffset(formId), CardDataService.getCardDays(formId));
    }).catch((err: BusinessError): void => {
      LogUtil.write(`卡片驱动同步失败: ${err.message}`);
    });
  }

  onRemoveForm(formId: string): void {
    LogUtil.init(this.context);
    LogUtil.write(`移除卡片: formId=${formId}`);
    CardDataService.unregisterForm(this.context, formId);
    CardDataService.clearDayOffset(formId);
    CardDataService.clearCardDays(formId);
  }

  /** 卡片上按钮触发：message 里带 pageAction=prev|next|today 或 cardDays=1|3|7 */
  onFormEvent(formId: string, message: string): void {
    LogUtil.init(this.context);
    const cur: number = CardDataService.getDayOffset(formId);
    let curDays: number = CardDataService.getCardDays(formId);
    if (curDays <= 0) {
      curDays = 1;
    }
    let next: number = cur;
    let nextDays: number = curDays;

    // 支持 1天 / 3天 / 7天 跨度切换及翻页
    if (message.indexOf('days_1') >= 0 || message.indexOf('"cardDays":1') >= 0) {
      nextDays = 1;
      next = 0;
      CardDataService.setCardDays(formId, 1);
    } else if (message.indexOf('days_3') >= 0 || message.indexOf('"cardDays":3') >= 0) {
      nextDays = 3;
      next = 0;
      CardDataService.setCardDays(formId, 3);
    } else if (message.indexOf('days_7') >= 0 || message.indexOf('"cardDays":7') >= 0) {
      nextDays = 7;
      next = 0;
      CardDataService.setCardDays(formId, 7);
    } else if (message.indexOf('prev') >= 0) {
      const step: number = (curDays === 7 ? 7 : (curDays === 3 ? 3 : 1));
      next = cur - step;
    } else if (message.indexOf('next') >= 0) {
      const step: number = (curDays === 7 ? 7 : (curDays === 3 ? 3 : 1));
      next = cur + step;
    } else if (message.indexOf('today') >= 0) {
      next = 0;
    }

    CardDataService.setDayOffset(formId, next);
    LogUtil.write(`卡片事件: formId=${formId} off=${cur}→${next}, days=${curDays}→${nextDays}`);
    this.pushData(formId, next, nextDays);
  }
}
