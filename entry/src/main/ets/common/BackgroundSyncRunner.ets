// entry/src/main/ets/common/BackgroundSyncRunner.ets
// ⭐ 后台同步的**唯一**执行体：延迟任务 / 短时任务 / 网络恢复 / 回到前台 都调它。
//
// 设计要点（2026-10-10 定时同步方案调研结论）：
//  - 不再依赖"进程常驻"（系统不允许，dataTransfer 长时任务会被强制取消）
//  - 而是让"最合适的机制在最合适的时机把数据对齐"
//  - 本类只负责"跑一次完整同步"，幂等（基于 etag 全量比对 + dirty 标记）
//
// ⚠️ 与 SyncEngine.syncAccount 的分工：本类不关心超时与互斥锁（由 SyncEngine 内部处理）。
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CALDAV } from './AccountStore';
import { SyncEngine } from './SyncEngine';
import { CardDataService } from './CardDataService';
import { ReminderService } from './ReminderService';
import { SystemCalendarImport } from './SystemCalendarImport';
import { SystemCalendarMirror } from './SystemCalendarMirror';
import { MirrorInbound } from './MirrorInbound';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';

/** 一次后台同步的结果（供日志/埋点，不做 UI） */
export class BackgroundSyncResult {
  ok: number = 0;
  attempted: number = 0;
  failed: number = 0;
}

export class BackgroundSyncRunner {
  /**
   * ⭐ 卡片的系统定时刷新间隔（与 form_config.json 的 updateDuration=1 保持一致，单位 30 分钟）。
   * ⚠️ 两处必须同步修改：改这里也要改 form_config.json，否则节流窗口对不上。
   */
  static readonly CARD_TICK_MS: number = 30 * 60 * 1000;
  /** 距上次同步不足该时长则跳过（略小于卡片周期，避免系统刷新漂移导致被误跳过） */
  private static readonly CARD_MIN_GAP_MS: number = 25 * 60 * 1000;
  /**
   * 卡片进程的软超时：官方规定 FormExtensionAbility 生命周期回调后进程**仅存续 10 秒**，
   * 超过就会被回收（异步任务被强制中止）。这里主动在 9 秒收手，
   * 让"这一次同步"**干净地放弃**而不是被硬杀在半途 —— 幂等同步中断本就不损坏数据，
   * 主动放弃还能保住"时间戳已写入、下轮再试"的一致性。
   */
  private static readonly CARD_SOFT_TIMEOUT_MS: number = 9 * 1000;

  /**
   * ⭐⭐ 由**服务卡片定时刷新**（`onUpdateForm`）驱动的后台同步（0.0.8）。
   *
   * 为什么用它：系统给普通应用的后台调度很受限 ——
   *   `workScheduler` 的周期被"应用活跃分组"压制到 **≥2 小时**；
   *   而服务卡片配置了 `updateDuration: 1`（**单位 30 分钟**），系统会**每 30 分钟**
   *   触发一次 `onUpdateForm()`，且不受活跃分组压制（每天上限 50 次）。
   *   借这个时机跑一次完整同步，即可得到"约 30 分钟一次"的定期后台同步。
   *
   * ⚠️ 节流：系统刷新本身可能有漂移、也可能因故重入 → 用时间戳挡一道，
   *    保证两次真实同步之间至少间隔 `CARD_MIN_GAP_MS`。
   * ⚠️ 本方法**永不抛错**（后台路径没有 UI 承担异常）。
   */
  static async runOnceThrottledByCard(context: common.Context): Promise<void> {
    try {
      const last: number = await AppSettings.getCardSyncAt(context);
      const now: number = Date.now();
      if (last > 0 && now - last < BackgroundSyncRunner.CARD_MIN_GAP_MS) {
        const mins: number = Math.round((now - last) / 60000);
        LogUtil.write(`卡片驱动同步：距上次仅 ${mins} 分钟，跳过（节流 ${BackgroundSyncRunner.CARD_MIN_GAP_MS / 60000} 分钟）`);
        return;
      }
      // 先写时间戳：避免同步执行期间卡片再次刷新导致并发重入
      await AppSettings.setCardSyncAt(context, now);
      LogUtil.write('卡片驱动同步：开始（卡片 30 分钟定时刷新触发）');
      // 软超时：9 秒内没跑完就主动放弃（进程本来也只有 10 秒窗口）
      const worker: Promise<void> =
        BackgroundSyncRunner.runOnce(context, 'cardTick').then((): void => {});
      const guard: Promise<void> = new Promise<void>((_res: () => void, rej: (e: Error) => void) => {
        setTimeout((): void => rej(new Error('卡片进程窗口不足，本次同步放弃')),
          BackgroundSyncRunner.CARD_SOFT_TIMEOUT_MS);
      });
      try {
        await Promise.race<void>([worker, guard]);
      } catch (err) {
        const e = err as Error;
        LogUtil.write(`卡片驱动同步提前收手：${e.message}（幂等，下轮会重试）`);
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`卡片驱动同步异常: ${e.message}`);
    }
  }
  /**
   * 跑一次完整同步。全流程 try-catch，**永不抛错**（后台路径没有 UI 承担异常）。
   * @param context 应用上下文
   * @param tag 日志标签，用于区分触发来源（deferred/transient/netRecover/foreground）
   */
  static async runOnce(context: common.Context, tag: string): Promise<BackgroundSyncResult> {
    const r = new BackgroundSyncResult();
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      if (accounts.length === 0) {
        LogUtil.write(`后台同步[${tag}]：无账号，跳过`);
        return r;
      }
      // 备份模式：先导入系统本地日历（幂等），再随同步推送
      try {
        await SystemCalendarImport.importIfNeeded(context);
      } catch (err) {
        // 导入失败不影响正常同步
      }
      // 入站对账：把用户在系统日历里的改动读回来置 dirty（必须在同步之前）
      try {
        await MirrorInbound.reconcile(context);
      } catch (err) {
        // 对账失败不影响正常同步
      }
      for (const acc of accounts) {
        if (acc.type !== TYPE_CALDAV) {
          continue;
        }
        r.attempted++;
        try {
          await SyncEngine.syncAccount(context, acc);
          r.ok++;
        } catch (err) {
          const e = err as BusinessError;
          // "已有同步进行中"不算失败（前台可能正在同步）
          r.failed++;
          LogUtil.write(`后台同步[${tag}] id=${acc.id} 失败: ${e.message}`);
        }
      }
      // 全部账号同步成功才结束"一次性全量重拉"状态
      if (r.attempted > 0 && r.ok === r.attempted) {
        await AppSettings.markFullRefetchDone(context);
      }
      await SyncEngine.settleLocalEvents(context);
      await SyncEngine.pruneOrphanRows(context, accounts);
      // ⚠️ 必须回写账号：syncAccount 会就地更新 acc（服务器日历本颜色、写权限等）。
      // 缺了这一步，后台同步刷到的颜色只留在内存里、进程退出即丢失。
      await AccountStore.saveAll(context, accounts);
      // 出站镜像：把服务器最新状态写进系统日历（自动化，无需手点）
      try {
        if (await AppSettings.getMirrorEnabled(context) && await SystemCalendarMirror.hasPermission()) {
          const mr = await SystemCalendarMirror.syncNow(context);
          LogUtil.write(`后台同步[${tag}] 自动镜像：本=${mr.books} 新增=${mr.added} 更新=${mr.updated} 删除=${mr.deleted}`);
        }
      } catch (err) {
        // 镜像失败不影响同步
      }
      // 同步后刷新卡片 + 重建提醒，保证后台同步的成果直接可见
      try {
        await CardDataService.pushToAllForms(context);
        await ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (err) {
        // 卡片/提醒刷新失败不影响同步结果
      }
      LogUtil.write(`后台同步[${tag}] 完成：${r.ok}/${r.attempted} 个账号`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`后台同步[${tag}] 流程异常: ${e.message}`);
    }
    return r;
  }
}