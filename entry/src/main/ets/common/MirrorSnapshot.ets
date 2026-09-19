// entry/src/main/ets/common/MirrorSnapshot.ets
// 镜像快照：记录"上一次我们把什么写进了系统日历"。
//
// 为什么必须有它（防回灌 / 防死循环）：
//   流程是 CalDAV → 本地库 → 写进系统日历。下一轮同步如果直接读系统日历当"用户改动"，
//   就会把我们刚写进去的当成用户改的 → 回写服务器 → 服务器变了 → 又镜像回系统日历 …… 死循环。
//   有了快照就能三方比对：
//     · 系统当前值 == 快照        → 没动，是我们自己写的，跳过
//     · 系统当前值 != 快照        → 用户在系统日历改了 → 回写 CalDAV
//     · 快照有、系统里没了        → 用户在系统日历删了 → 从 CalDAV 删
//     · 系统里有、快照没有且 identifier 不是我们的格式 → 用户在系统日历新建 → 加进 CalDAV
//
// ⚠️ 只存"状态指纹"，**不存日程内容**（内容仍在系统日历与本地库各一份，这是阶段 2 的取舍）。
//    日程内容只有一份的形态（阶段 3）需要配合"影子表 + 系统日历为内容源"，那是另一件事。

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { calendarManager } from '@kit.CalendarKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogUtil } from './LogUtil';

/**
 * 快照行。
 * ⚠️ `calKey` 这一列实际存的是**镜像桶标识 = bookId**（由服务器 href 派生的稳定标识），
 *    与系统日历侧 identifier 前缀、账户名后缀完全一致。列名沿用未改，别再传会变的 calKey。
 */
export class MirrorSnapshotRow {
  identifier: string = '';  // `<bookId>|<uid>`
  calKey: string = '';
  uid: string = '';
  sysId: number = -1;       // 系统日历里的 event id（删除时用）
  fingerprint: string = ''; // 写入值的内容指纹
}

export class MirrorSnapshot {
  private static readonly TABLE: string = 'mirror_snapshot';
  private static ready: boolean = false;

  /* ==================== 表 ==================== */

  private static async db(context: common.Context): Promise<relationalStore.RdbStore> {
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, {
      name: 'sync_calendar.db',
      securityLevel: relationalStore.SecurityLevel.S1
    });
    if (!MirrorSnapshot.ready) {
      await store.executeSql(
        'CREATE TABLE IF NOT EXISTS mirror_snapshot (' +
        'identifier TEXT PRIMARY KEY, cal_key TEXT, uid TEXT, ' +
        'sys_id INTEGER, fingerprint TEXT, updated_at INTEGER)'
      );
      MirrorSnapshot.ready = true;
    }
    return store;
  }

  /* ==================== 读写 ==================== */

  /** 取某个日历本的全部快照，key = identifier。**bucket 必须是 bookId** */
  static async loadMap(context: common.Context, bucket: string): Promise<Map<string, MirrorSnapshotRow>> {
    const out: Map<string, MirrorSnapshotRow> = new Map<string, MirrorSnapshotRow>();
    try {
      const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
      const predicates = new relationalStore.RdbPredicates(MirrorSnapshot.TABLE);
      predicates.equalTo('cal_key', bucket);
      const rs = await store.query(predicates);
      try {
        while (rs.goToNextRow()) {
          const row: MirrorSnapshotRow = new MirrorSnapshotRow();
          row.identifier = rs.getString(rs.getColumnIndex('identifier'));
          row.calKey = bucket;
          row.uid = rs.getString(rs.getColumnIndex('uid'));
          row.sysId = rs.getLong(rs.getColumnIndex('sys_id'));
          row.fingerprint = rs.getString(rs.getColumnIndex('fingerprint'));
          out.set(row.identifier, row);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`读取镜像快照失败 bucket=${bucket}: ${e.message}`);
    }
    return out;
  }

  /**
   * **整体重建**某个日历本的快照：先删光旧行，再写入新行。
   * 为什么不用增量：出站镜像后直接把系统日历里该账户的实际内容重新读一遍再落快照最稳，
   * 不用在写入过程中追踪 addEvent 返回的 id（批量 addEvents 还不返回 id）。
   */
  static async replaceAll(
    context: common.Context,
    bucket: string,
    events: calendarManager.Event[]
  ): Promise<number> {
    let n: number = 0;
    try {
      const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
      const del = new relationalStore.RdbPredicates(MirrorSnapshot.TABLE);
      del.equalTo('cal_key', bucket);
      await store.delete(del);
      const now: number = Date.now();
      for (const ev of events) {
        const id: string = ev.identifier ?? '';
        if (id === '') {
          continue; // 用户在系统日历自己加的、没有我们 identifier 的 → 不进快照（由入站对账新建）
        }
        const vb: relationalStore.ValuesBucket = {
          'identifier': id,
          'cal_key': bucket,
          'uid': MirrorSnapshot.uidOf(id),
          'sys_id': ev.id ?? -1,
          'fingerprint': MirrorSnapshot.fingerprintOf(ev),
          'updated_at': now
        };
        await store.insert(MirrorSnapshot.TABLE, vb);
        n++;
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`重建镜像快照失败 bucket=${bucket}: ${e.message}`);
    }
    return n;
  }

  /** 写入/更新单条快照（入站回写成功后同步指纹，避免下次重复判定为"用户改了"） */
  static async put(context: common.Context, row: MirrorSnapshotRow): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
      const bucket: relationalStore.ValuesBucket = {
        'identifier': row.identifier,
        'cal_key': row.calKey,
        'uid': row.uid,
        'sys_id': row.sysId,
        'fingerprint': row.fingerprint,
        'updated_at': Date.now()
      };
      await store.insert(MirrorSnapshot.TABLE, bucket);
    } catch (err) {
      // 主键冲突时改成 update
      try {
        const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
        const bucket: relationalStore.ValuesBucket = {
          'sys_id': row.sysId,
          'fingerprint': row.fingerprint,
          'updated_at': Date.now()
        };
        const predicates = new relationalStore.RdbPredicates(MirrorSnapshot.TABLE);
        predicates.equalTo('identifier', row.identifier);
        await store.update(bucket, predicates);
      } catch (err2) {
        const e = err2 as BusinessError;
        LogUtil.write(`写入镜像快照失败 ${row.identifier}: ${e.message}`);
      }
    }
  }

  /** 删除单条（用户删了 / 本地已不存在） */
  static async remove(context: common.Context, identifier: string): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
      const predicates = new relationalStore.RdbPredicates(MirrorSnapshot.TABLE);
      predicates.equalTo('identifier', identifier);
      await store.delete(predicates);
    } catch (err) {
      // 忽略
    }
  }

  /** 删除整个日历本的快照（取消勾选 / 关闭镜像时调用）。bucket = bookId */
  static async removeByCalKey(context: common.Context, bucket: string): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
      const predicates = new relationalStore.RdbPredicates(MirrorSnapshot.TABLE);
      predicates.equalTo('cal_key', bucket);
      await store.delete(predicates);
    } catch (err) {
      // 忽略
    }
  }

  /** 清空全部快照（关闭镜像总开关时用，顺带清掉历史遗留的 calKey 键） */
  static async clearAll(context: common.Context): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await MirrorSnapshot.db(context);
      const predicates = new relationalStore.RdbPredicates(MirrorSnapshot.TABLE);
      await store.delete(predicates);
    } catch (err) {
      // 忽略
    }
  }

  /* ==================== 指纹 ==================== */

  /**
   * 事件内容指纹。用于判断"系统日历里这条，是不是还是我们上次写进去的样子"。
   * ⚠️ 全天日程的 endTime 会被系统归一化（我们写次日 00:00，可能读回 23:59:59.999），
   * 所以全天一律折成"日"再算指纹，否则每次都判定成"用户改了"。
   */
  static fingerprintOf(ev: calendarManager.Event): string {
    const allDay: boolean = ev.isAllDay === true;
    let start: number = ev.startTime;
    let end: number = ev.endTime;
    if (allDay) {
      start = MirrorSnapshot.dayStart(start);
      end = MirrorSnapshot.dayStart(end - 1);
    }
    const raw: string = [
      ev.title ?? '',
      `${start}`,
      `${end}`,
      allDay ? '1' : '0',
      ev.location?.location ?? '',
      ev.description ?? '',
      MirrorSnapshot.hash(ev.recurrenceRule !== undefined ? JSON.stringify(ev.recurrenceRule) : '')
    ].join('\u0001');
    return `${MirrorSnapshot.hash(raw)}:${MirrorSnapshot.hash(raw, 5381)}`;
  }

  /** identifier (`<calKey>|<uid>`) → uid */
  static uidOf(identifier: string): string {
    const pos: number = identifier.indexOf('|');
    return pos < 0 ? '' : identifier.substring(pos + 1);
  }

  private static dayStart(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** 简单字符串哈希（djb2 变体）。两个不同种子各算一次拼起来，降低碰撞概率 */
  private static hash(s: string, seed?: number): string {
    let h: number = seed === undefined ? 0 : seed;
    for (let i: number = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    }
    return (h >>> 0).toString(36);
  }
}
