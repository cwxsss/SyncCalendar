// entry/src/main/ets/common/LogUtil.ets
// 日志功能已按需求移除：保留空实现以兼容既有调用点（不写文件、不再缓冲）
import { common } from '@kit.AbilityKit';

export class LogUtil {
  static logFilePath(): string {
    return '';
  }

  /** 空实现（日志功能已移除） */
  static init(context: common.Context): void {
  }

  /** 仅输出到 console（hilog），不再写文件 */
  static write(msg: string): void {
    console.info(`SyncLog ${msg}`);
  }

  static readAll(context: common.Context): string {
    return '(日志功能已移除)';
  }

  static clear(context: common.Context): void {
  }
}
