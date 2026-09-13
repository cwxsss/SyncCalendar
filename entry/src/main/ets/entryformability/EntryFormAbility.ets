// entry/src/main/ets/entryformability/EntryFormAbility.ets
// 服务卡片 FormExtensionAbility：添加卡片时注入初始数据，定时/触发时更新
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CardDataService, CardData } from '../common/CardDataService';
import { LogUtil } from '../common/LogUtil';

export default class EntryFormAbility extends FormExtensionAbility {
  /** 组装更新数据并推送到指定卡片 */
  private pushData(formId: string): void {
    CardDataService.buildCardData(this.context).then((data: CardData): void => {
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
    this.pushData(formId);
  }

  onRemoveForm(formId: string): void {
    LogUtil.init(this.context);
    LogUtil.write(`移除卡片: formId=${formId}`);
    CardDataService.unregisterForm(this.context, formId);
  }
}
