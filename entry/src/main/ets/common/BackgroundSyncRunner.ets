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