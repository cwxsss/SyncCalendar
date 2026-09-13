// entry/src/main/ets/common/LogUtil.ets
// 同步日志：写入应用 filesDir/sync.log（含时间戳），超 512KB 自动截断保留后半。
// 设置页「同步日志」卡片可查看/复制/清空，方便真机测试时诊断同步与提醒问题。
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class LogUtil {
  private static path: string = '';
  private static readonly MAX_BYTES: number = 512 * 1024;

  static init(context: common.Context): void {
    try {
      LogUtil.path = `${context.filesDir}/sync.log`;
    } catch (err) {
      LogUtil.path = '';
    }
  }

  static logFilePath(): string {
    return LogUtil.path;
  }

  /** 写一行日志：console + 文件（文件失败静默，不影响业务） */
  static write(msg: string): void {
    console.info(`SyncLog ${msg}`);
    if (LogUtil.path === '') {
      return;
    }
    try {
      const d = new Date();
      const p = (n: number): string => n < 10 ? '0' + n : String(n);
      const ts: string = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}` +
        ` ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
      // 超限截断：保留最后 256KB
      try {
        const st: fs.Stat = fs.statSync(LogUtil.path);
        if (st.size > LogUtil.MAX_BYTES) {
          LogUtil.truncate();
        }
      } catch (err) {
        // 文件不存在属正常，直接创建写入
      }
      const file: fs.File = fs.openSync(LogUtil.path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, `[${ts}] ${msg}\n`);
      fs.closeSync(file.fd);
    } catch (err) {
      // 写日志失败不影响业务
    }
  }

  /** 截断：只保留文件末尾 256KB */
  private static truncate(): void {
    try {
      const keep: number = 256 * 1024;
      const st: fs.Stat = fs.statSync(LogUtil.path);
      const size: number = Math.min(st.size, keep);
      const file = fs.openSync(LogUtil.path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buf, { offset: st.size - size });
      fs.closeSync(file.fd);
      const out = fs.openSync(LogUtil.path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, `…（日志过长，已截断保留末尾）\n`);
      fs.writeSync(out.fd, new Uint8Array(buf));
      fs.closeSync(out.fd);
    } catch (err) {
      // 截断失败忽略，下次再试
    }
  }

  static readAll(context: common.Context): string {
    try {
      if (LogUtil.path === '') {
        LogUtil.init(context);
      }
      if (LogUtil.path === '') {
        return '(无法确定日志路径)';
      }
      const st: fs.Stat = fs.statSync(LogUtil.path);
      if (st.size === 0) {
        return '(日志为空)';
      }
      const file = fs.openSync(LogUtil.path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file.fd);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (err) {
      return `(读取日志失败: ${(err as BusinessError).message})`;
    }
  }

  static clear(context: common.Context): void {
    try {
      if (LogUtil.path === '') {
        LogUtil.init(context);
      }
      fs.unlinkSync(LogUtil.path);
    } catch (err) {
      // 文件不存在等，忽略
    }
  }
}
