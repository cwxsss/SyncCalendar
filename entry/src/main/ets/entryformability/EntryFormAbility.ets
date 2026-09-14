// entry/src/main/ets/entryformability/EntryFormAbility.ets
// 服务卡片 FormExtensionAbility：添加卡片时注入初始数据，定时/触发时更新
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CardDataService, CardData } from '../common/CardDataService';
import { LogUtil } from '../common/LogUtil';

export default class EntryFormAbility extends FormExtensionAbility {
  /** 组装更新数据并推送到指定卡片 */
  private pushData(formId: string, dayOffset: number = 0): void {
    CardDataService.buildCardData(this.context, dayOffset).then((data: CardData): void => {
      const binding: formBindingData.FormBindingData =
        formBindingData.createFormBindingData(data);
      formProvider.updateForm(formId, binding).catch((err: BusinessError): void => {
        LogUtil.write(`卡片 ${formId} 更新失败: ${err.message}`);
      });
      LogUtil.write(`卡片 ${formId} 数据已推送`);
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
    LogUtil.write(`系统触发卡片更新: formId=${formId}`);
    CardDataService.registerForm(this.context, formId);
    // 保留用户翻到的日期（系统定时刷新不应把用户翻走的日期拽回今天）
    this.pushData(formId, CardDataService.getDayOffset(formId));
  }

  onRemoveForm(formId: string): void {
    LogUtil.init(this.context);
    LogUtil.write(`移除卡片: formId=${formId}`);
    CardDataService.unregisterForm(this.context, formId);
    CardDataService.clearDayOffset(formId);
  }

  /** 卡片上「‹ / › / 回到今天」按钮触发：message 里带 pageAction=prev|next|today */
  onFormEvent(formId: string, message: string): void {
    LogUtil.init(this.context);
    const cur: number = CardDataService.getDayOffset(formId);
    let next: number = cur;
    // 不用 JSON 解析：不同版本 message 的格式可能是 {params:{...}} 或直接 {...}，直接子串匹配更稳
    if (message.indexOf('prev') >= 0) {
      next = cur - 1;
    } else if (message.indexOf('next') >= 0) {
      next = cur + 1;
    } else if (message.indexOf('today') >= 0) {
      next = 0;
    }
    CardDataService.setDayOffset(formId, next);
    LogUtil.write(`卡片翻页: formId=${formId} ${cur} → ${next}`);
    this.pushData(formId, next);
  }
}
