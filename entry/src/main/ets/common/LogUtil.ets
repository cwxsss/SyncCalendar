// entry/src/main/ets/common/LogUtil.ets
// 日志工具：默认**只输出到 console（hilog）**，不落盘。
//
// ⭐ 0.0.8 起：发行版**不再写 sync.log**（原「同步记录」/诊断落盘功能已移除）。
//   需要真机排查同步/提醒问题时，把下面的 ENABLE_FILE_LOG 改成 true 重新编译即可恢复
//   落盘（含 512KB 自动截断保留后半），其余调用点一行都不用动。
//   关闭状态下会在 init 时顺手删掉历史版本遗留的 sync.log 与 mirror_diag.txt，
//   保证升级上来的设备沙箱也是干净的。
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class LogUtil {
  /** ⭐ 落盘开关：发行版置 false（仅 console）；真机排查时改 true 恢复文件日志 */
  private static readonly ENABLE_FILE_LOG: boolean = false;
  private static dir: string = '';
  private static path: string = '';
  private static readonly MAX_BYTES: number = 512 * 1024;

  static init(context: common.Context): void {
    try {
      LogUtil.dir = context.filesDir;
      LogUtil.path = `${LogUtil.dir}/sync.log`;
    } catch (err) {
      LogUtil.dir = '';
      LogUtil.path = '';
    }
    if (!LogUtil.ENABLE_FILE_LOG && LogUtil.dir !== '') {
      LogUtil.removeLegacyDebugFiles();
    }
  }

  /** 删除历史版本遗留的调试落盘文件（sync.log / mirror_diag.txt） */
  private static removeLegacyDebugFiles(): void {
    for (const name of ['sync.log', 'mirror_diag.txt']) {
      try {
        fs.unlinkSync(`${LogUtil.dir}/${name}`);
      } catch (err) {
        // 文件不存在属正常，忽略
      }
    }
  }

  static logFilePath(): string {
    return LogUtil.path;
  }

  /** 写一行日志：console + 文件（发行版不落盘；文件失败静默，不影响业务） */
  static write(msg: string): void {
    console.info(`SyncLog ${msg}`);
    if (!LogUtil.ENABLE_FILE_LOG) {
      return;
    }
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
