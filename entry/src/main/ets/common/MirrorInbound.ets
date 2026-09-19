// entry/src/main/ets/common/MirrorInbound.ets
// 入站对账：把"用户在系统日历里做的改动"读回来，写回本地库并置 dirty，随下一次同步推送到 CalDAV。
//
// 这是「系统日历 ↔ 同步日历 App ↔ CalDAV 服务器」闭环的**回程**。
// 出站（CalDAV → 系统日历）在 SystemCalendarMirror，本文件负责反向。
//
// ⚠️ 防回灌是这里唯一的核心难题：系统日历里既有"我们写进去的"，也有"用户改的/新建的/删的"，
//    靠 `MirrorSnapshot`（上次写入值的内容指纹）区分：
//
//    | 系统日历当前状态                    | 判定             | 动作                      |
//    |-----------------------------------|------------------|---------------------------|
//    | 有 identifier，指纹 == 快照          | 我们自己写的      | 跳过                      |
//    | 有 identifier，指纹 != 快照          | 用户改了          | 写回本地库 → 置 dirty 推送  |
//    | 有 identifier，但**没有快照**        | 认作是我们写的    | **补快照后跳过**（不误判）  |
//    | 快照有，系统里没了                   | 用户删了          | markDeleted → 推送 DELETE |
//    | identifier 不是我们的格式            | 用户在系统日历新建 | 新建 LocalEvent → 推送     |
//
// ⚠️ "没有快照就补快照后跳过"这条非常关键：首次启用回写时快照是空的，
//    若按"无快照＝用户改了"处理，会把全部日程标脏、全量重推服务器。

import { common } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventDb, LocalEvent } from './EventDb';
import { LogUtil } from './LogUtil';
import { AppSettings } from './AppSettings';
import { MirrorSnapshot, MirrorSnapshotRow } from './MirrorSnapshot';
import { BookRef, SystemCalendarMirror } from './SystemCalendarMirror';

/** 一次入站对账的统计 */
export class InboundResult {
  created: number = 0; // 系统日历新建 → 加进 CalDAV
  updated: number = 0; // 系统日历修改 → 回写 CalDAV
  deleted: number = 0; // 系统日历删除 → 从 CalDAV 删
  skipped: number = 0;
  failed: number = 0;
}

export class MirrorInbound {
  private static readonly DAY: number = 86400000;
  private static readonly QUERY_FIELDS: (keyof calendarManager.Event)[] = [
    'id', 'type', 'title', 'startTime', 'endTime', 'isAllDay',
    'description', 'location', 'identifier', 'reminderTime', 'recurrenceRule'
  ];

  /**
   * 入站对账主入口。
   * ⚠️ 必须在 `SyncEngine.syncAccount()` **之前**调用 —— 它产生的 dirty 行要借本次同步一起推送。
   */
  static async reconcile(context: common.Context): Promise<InboundResult> {
    const res: InboundResult = new InboundResult();
    try {
      const on: boolean = await AppSettings.getMirrorInbound(context);
      if (!on) {
        return res;
      }
      if (!await SystemCalendarMirror.hasPermission()) {
        return res;
      }
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      // ⭐ 与出站镜像用**同一套**稳定引用（bookId 由服务器 href 派生），否则两边对不上号
      const refs: BookRef[] = await SystemCalendarMirror.selectedBookRefs(context);
      for (const ref of refs) {
        try {
          await MirrorInbound.reconcileBook(context, cm, ref, res);
        } catch (err) {
          const e = err as BusinessError;
          res.failed++;
          LogUtil.write(`入站对账失败 bookId=${ref.bookId}: ${e.code ?? ''} ${e.message}`);
        }
      }
      if (res.created + res.updated + res.deleted > 0) {
        LogUtil.write(
          `入站对账：新建=${res.created} 修改=${res.updated} 删除=${res.deleted} 跳过=${res.skipped}`);
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`入站对账异常: ${e.message}`);
    }
    return res;
  }

  /* ==================== 单个日历本 ==================== */

  private static async reconcileBook(
    context: common.Context,
    cm: calendarManager.CalendarManager,
    ref: BookRef,
    res: InboundResult
  ): Promise<void> {
    const calKey: string = ref.calKey; // 仅用于查本地库
    const bucket: string = ref.bookId; // ⭐ 系统日历侧的一切标识都用 bookId
    const accountName: string = ref.sysAccountName;
    let cal: calendarManager.Calendar | undefined = undefined;
    const calendars: calendarManager.Calendar[] = await cm.getAllCalendars();
    for (const c of calendars) {
      if (c.getAccount().name === accountName) {
        cal = c;
        break;
      }
    }
    if (cal === undefined) {
      return; // 还没镜像过，无从对账
    }
    const href: string = ref.href;
    if (href === '') {
      LogUtil.write(`入站对账跳过 bookId=${bucket}：找不到对应的日历本集合 URL`);
      return;
    }

    const snaps: Map<string, MirrorSnapshotRow> = await MirrorSnapshot.loadMap(context, bucket);
    const events: calendarManager.Event[] = await cal.getEvents(
      undefined, MirrorInbound.QUERY_FIELDS);

    // 分成两类：带我们 identifier 的（可判定改/删） vs 不是我们的（用户新建）
    const mine: Map<string, calendarManager.Event> = new Map<string, calendarManager.Event>();
    const others: calendarManager.Event[] = [];
    for (const ev of events) {
      const id: string = ev.identifier ?? '';
      if (id !== '' && id.startsWith(`${bucket}|`)) {
        mine.set(id, ev);
      } else {
        others.push(ev);
      }
    }

    // 本地库现有事件：uid -> LocalEvent
    const locals: LocalEvent[] = await EventDb.queryByCalKey(context, calKey, 'event');
    const byUid: Map<string, LocalEvent> = new Map<string, LocalEvent>();
    for (const e of locals) {
      if (e.uid !== '') {
        byUid.set(e.uid, e);
      }
    }

    // ① 修改
    for (const id of mine.keys()) {
      const ev: calendarManager.Event | undefined = mine.get(id);
      if (ev === undefined) {
        continue;
      }
      const fp: string = MirrorSnapshot.fingerprintOf(ev);
      const snap: MirrorSnapshotRow | undefined = snaps.get(id);
      if (snap === undefined) {
        // ⚠️ 没有快照：认作是我们自己写的，补一份后跳过 —— 绝不误判成"用户改了"
        await MirrorSnapshot.put(context, MirrorInbound.rowOf(bucket, id, ev, fp));
        res.skipped++;
        continue;
      }
      snaps.delete(id); // 还活着，稍后剩下的才是"被删了"
      if (snap.fingerprint === fp) {
        res.skipped++; // 没动
        continue;
      }
      // ⚠️ 重复日程的**某一次发生**（identifier 形如 `<bookId>|<uid>@<发生时间戳>`）：
      //    它是我们从一条重复日程展开出来的，不是独立事件 —— 改它没法映射回服务器上的
      //    那一条 VEVENT，直接跳过，避免把服务器数据搞乱。
      if (MirrorInbound.isOccurrence(id)) {
        res.skipped++;
        await MirrorSnapshot.put(context, MirrorInbound.rowOf(bucket, id, ev, fp));
        continue;
      }
      const uid: string = MirrorSnapshot.uidOf(id);
      const local: LocalEvent | undefined = byUid.get(uid);
      if (local === undefined) {
        res.skipped++; // 本地已无此条（服务器删了/还没落库）→ 交给出站镜像处理
        continue;
      }
      if (local.dirty || local.deleted) {
        res.skipped++; // 本地本来就有待推送的改动 → 不拿系统值覆盖，避免两边打架
        continue;
      }
      MirrorInbound.applyToLocal(local, ev);
      await EventDb.updateLocal(context, local);
      await MirrorSnapshot.put(context, MirrorInbound.rowOf(bucket, id, ev, fp));
      res.updated++;
      LogUtil.write(`入站修改回写：${id}（${local.title}）`);
    }

    // ② 删除：快照里剩下的（系统日历里已经没有了）
    for (const id of snaps.keys()) {
      const snap: MirrorSnapshotRow | undefined = snaps.get(id);
      if (snap === undefined) {
        continue;
      }
      // 同上：展开出来的"某一次发生"消失（多半是滑出镜像窗口），不能当成用户删除
      if (MirrorInbound.isOccurrence(id)) {
        res.skipped++;
        await MirrorSnapshot.remove(context, id);
        continue;
      }
      const local: LocalEvent | undefined = byUid.get(snap.uid);
      if (local !== undefined && !local.deleted) {
        await EventDb.markDeleted(context, local.id);
        res.deleted++;
        LogUtil.write(`入站删除回写：${id}（${local.title}）`);
      } else {
        res.skipped++;
      }
      await MirrorSnapshot.remove(context, id);
    }

    // ③ 新建：系统日历里 identifier 不是我们格式的条目（用户在系统日历里手动加的）
    for (const ev of others) {
      if (ev.id === undefined) {
        continue;
      }
      const uid: string = `sc-${bucket}-${ev.id}`;
      if (byUid.has(uid)) {
        continue;
      }
      // ⚠️ 先把 identifier 写回系统日历，让它变成"我们的"条目。
      //    否则下一次出站镜像会把同一条再加一遍 → 系统日历里出现重复。
      const identifier: string = `${bucket}|${uid}`;
      const stamped: calendarManager.Event = ev;
      stamped.identifier = identifier;
      try {
        await cal.updateEvent(stamped);
      } catch (err) {
        const e = err as BusinessError;
        res.skipped++;
        LogUtil.write(`入站新建跳过：无法写回 identifier（${e.message}），避免重复`);
        continue;
      }
      const e: LocalEvent = new LocalEvent();
      e.uid = uid;
      e.calKey = calKey;
      e.href = href;
      e.remotePath = encodeURIComponent(uid) + '.ics';
      e.kind = 'event';
      MirrorInbound.applyToLocal(e, ev);
      await EventDb.insertLocal(context, e);
      await MirrorSnapshot.put(context, MirrorInbound.rowOf(
        bucket, identifier, ev, MirrorSnapshot.fingerprintOf(ev)));
      res.created++;
      LogUtil.write(`入站新建回写：${identifier}（${e.title}）`);
    }
  }

  /* ==================== 辅助 ==================== */

  /**
   * 是不是"重复系列里的某一次发生"？identifier 形如 `<bookId>|<uid>@<发生时间戳>`。
   *
   * ⚠️ 不能用 `includes('@')` 判断：**uid 本身就常含 @**（如 `20260906T163329-d13e0cb6@172.17.0.1`），
   *    会误判。只有"最后一段是纯数字"才是我们加的发生时间戳。
   */
  private static isOccurrence(id: string): boolean {
    const pos: number = id.lastIndexOf('@');
    if (pos < 0) {
      return false;
    }
    const tail: string = id.substring(pos + 1);
    if (tail === '') {
      return false;
    }
    for (let i: number = 0; i < tail.length; i++) {
      const c: string = tail[i];
      if (c < '0' || c > '9') {
        return false;
      }
    }
    return true;
  }

  private static rowOf(
    bucket: string,
    identifier: string,
    ev: calendarManager.Event,
    fp: string
  ): MirrorSnapshotRow {
    const row: MirrorSnapshotRow = new MirrorSnapshotRow();
    row.identifier = identifier;
    row.calKey = bucket;
    row.uid = MirrorSnapshot.uidOf(identifier);
    row.sysId = ev.id ?? -1;
    row.fingerprint = fp;
    return row;
  }

  /** 系统日历 Event → 本工程 LocalEvent（只覆盖可映射字段） */
  private static applyToLocal(e: LocalEvent, ev: calendarManager.Event): void {
    e.title = ev.title ?? '';
    e.description = ev.description ?? '';
    e.location = ev.location?.location ?? '';
    e.startTime = ev.startTime;
    e.isAllDay = ev.isAllDay === true;
    // 系统全天 endTime 可能是"次日 00:00"，也可能是"当日 23:59:59.999"
    // → 统一成本工程约定："排他结束日前一毫秒"
    e.endTime = e.isAllDay
      ? MirrorInbound.dayStart(ev.endTime - 1) + MirrorInbound.DAY - 1
      : ev.endTime;
    e.rrule = MirrorInbound.rruleOf(ev);
    e.recurring = e.rrule !== '';
    if (ev.reminderTime !== undefined && ev.reminderTime.length > 0) {
      e.reminders = [...ev.reminderTime];
      e.reminder = ev.reminderTime[0];
    }
  }

  private static dayStart(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** 系统 RecurrenceRule → RRULE 字符串（仅 FREQ/INTERVAL；复杂规则以服务器端为准） */
  private static rruleOf(ev: calendarManager.Event): string {
    try {
      const rr = ev.recurrenceRule;
      if (rr === undefined) {
        return '';
      }
      const freqMap: string[] = ['YEARLY', 'MONTHLY', 'WEEKLY', 'DAILY'];
      const fi: number = rr.recurrenceFrequency as number;
      if (Number.isNaN(fi) || fi < 0 || fi >= freqMap.length) {
        return '';
      }
      let rrule: string = `FREQ=${freqMap[fi]}`;
      if (rr.interval !== undefined && rr.interval > 1) {
        rrule += `;INTERVAL=${rr.interval}`;
      }
      return rrule;
    } catch (err) {
      return '';
    }
  }
}
