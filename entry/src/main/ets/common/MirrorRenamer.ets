// entry/src/main/ets/common/MirrorRenamer.ets
// ⭐ 一键重命名镜像账户的显示名（0.0.8）
//
// 为什么需要这个模块：HarmonyOS 的 `@ohos.calendarManager` **没有"修改账户"的 API**
//   （只有 create/delete/get/getAll；CalendarConfig 仅 enableReminder+color；
//     CalendarAccount.name 是 readonly）→ `displayName` 只能在创建时定，之后改不了。
//   ⇒ 想换显示名，只能"**删掉旧账户 → 按新名字重建**"。
//
// ⭐⭐ 安全顺序（不可调换）：先回读 → 再删 → 重建 → 全量重写
//   ① `MirrorInbound.reconcile()`：把用户在系统日历里**手动新建/修改**的日程先收进本地库（置 dirty）
//      —— 因为 `deleteCalendar` 会删掉该账户下**所有**日程（含用户手动加的），不回读就会丢数据。
//   ② 删除旧镜像账户（按 bookId 精确定位）
//   ③ 立即 `syncNow()`：按用户所选的新格式重建账户并全量写回（含刚回读的 dirty 项）
//
// 为什么放在独立模块：`MirrorInbound` 已经 import 了 `SystemCalendarMirror`，
//   若再把 `MirrorInbound` 反向 import 进 `SystemCalendarMirror` 会形成循环依赖；
//   本模块作为"编排层"同时依赖二者，方向单一、无环。
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SystemCalendarMirror, BookRef, MirrorResult } from './SystemCalendarMirror';
import { MirrorInbound, InboundResult } from './MirrorInbound';
import { LogUtil } from './LogUtil';

/** 重命名结果（供 UI 提示） */
export class RenameResult {
  ok: boolean = false;
  readBack: number = 0;   // 回读到的用户改动条数（created+updated+deleted）
  removed: number = 0;    // 删除的旧账户数
  mirrored: number = 0;   // 重建后镜像的日历本数
  message: string = '';
}

export class MirrorRenamer {
  /**
   * 按当前（已落盘的）显示名格式，重建全部镜像账户的显示名。
   *
   * ⚠️ 前提：调用方已把用户所选格式写入 `AppSettings`（`setMirrorDisplayFormat`）；
   *    本方法只负责"按现有配置重新应用"。
   * ⚠️ 需要系统日历读写权限（调用方先校验 / 申请）。
   */
  static async reapplyDisplayNames(context: common.Context): Promise<RenameResult> {
    const res = new RenameResult();
    if (!await SystemCalendarMirror.hasPermission()) {
      res.message = '未获得系统日历读写权限';
      return res;
    }

    // ① 先回读：把用户在系统日历里的手动新建/修改收进本地库（置 dirty），避免删除时丢数据
    try {
      const inbound: InboundResult = await MirrorInbound.reconcile(context);
      res.readBack = inbound.created + inbound.updated + inbound.deleted;
      LogUtil.write(`重命名-回读完成：新增=${inbound.created} 修改=${inbound.updated} 删除=${inbound.deleted}`);
    } catch (err) {
      // 回读失败 → **中止重命名**（宁可不改，也不能冒着丢数据的风险删账户）
      const e = err as BusinessError;
      LogUtil.write(`重命名中止：回读失败 ${e.message}`);
      res.message = '未能先同步系统日历中的改动，已取消操作（避免数据丢失）。请稍后重试。';
      return res;
    }

    // ② 取出当前选中的镜像本（当前配置）
    let refs: BookRef[] = [];
    try {
      refs = await SystemCalendarMirror.selectedBookRefs(context);
    } catch (err) {
      res.message = '读取镜像日历本失败';
      return res;
    }
    if (refs.length === 0) {
      res.message = '当前没有选中的镜像日历本';
      return res;
    }

    // ③ 删除这些本的旧镜像账户（按 bookId，与名字无关）
    const bookIds: string[] = refs.map((r: BookRef): string => r.bookId);
    res.removed = await SystemCalendarMirror.removeAccountsByBookIds(context, bookIds);
    LogUtil.write(`重命名：已删除 ${res.removed} 个旧账户，准备按新格式重建`);

    // ④ 立即按新格式重建并全量写回（含刚回读的 dirty 项）
    try {
      const mr: MirrorResult = await SystemCalendarMirror.syncNow(context);
      res.mirrored = mr.books;
      res.ok = true;
      res.message = '已按新的显示方式重新写入系统日历';
      LogUtil.write(`重命名完成：重建 ${mr.books} 个本（新增=${mr.added} 更新=${mr.updated} 删除=${mr.deleted}）`);
    } catch (err) {
      const e = err as BusinessError;
      res.ok = false;
      res.message = `重建失败：${e.message}`;
      LogUtil.write(`重命名重建失败：${e.message}`);
    }
    return res;
  }

  /**
   * 检测是否还有"旧格式"（`同步日历 · xxx`）的镜像账户 —— 用于设置页给出"可更换"的弱提示。
   * 只读，不做任何修改。
   */
  static async hasLegacyNamedAccounts(context: common.Context): Promise<boolean> {
    return await SystemCalendarMirror.hasLegacyDisplayName(context);
  }
}