// entry/src/main/ets/common/EventDb.ets
// 本地事件数据库（relationalStore）：DAV 同步来的日程与本地新建日程统一存储
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 本地事件行 */
export class LocalEvent {
  id: number = 0;
  uid: string = '';
  calKey: string = '';      // 'accId_idx' 或 'local'
  href: string = '';        // 所属日历本集合 URL（local 为空）
  remotePath: string = '';  // 集合内资源文件名，如 <uid>.ics（local 为空）
  title: string = '';
  description: string = '';
  location: string = '';
  startTime: number = 0;    // 13 位毫秒；全天日程为当天 0 点
  endTime: number = 0;      // 全天日程为排他结束日前一毫秒（沿用 iCal 约定减 1s 存储）
  isAllDay: boolean = false;
  etag: string = '';
  dirty: boolean = false;   // 本地有修改，待推送
  deleted: boolean = false; // 本地已删除，待推送
  recurring: boolean = false; // 重复日程实例（暂不支持推送，避免破坏服务器序列）
  kind: string = 'event';   // 'event' 日程 | 'todo' 待办（VTODO，只读展示）
  completed: boolean = false; // 待办是否已完成（STATUS:COMPLETED）
  rrule: string = '';       // 原始 RRULE（空 = 非重复）；显示时按规则展开多次发生
  exdate: string = '';      // 原始 EXDATE 排除日期，分号分隔
  reminder: number = 0;     // 主提醒提前分钟数（第一个提醒，兼容旧字段），0 = 不提醒
  reminders: number[] = []; // 全部提醒提前分钟数（多选），按添加顺序
}

/** 远端事件条目（REPORT 解析结果） */
export class RemoteEvent {
  uid: string = '';
  etag: string = '';
  title: string = '';
  description: string = '';
  location: string = '';
  startTime: number = 0;
  endTime: number = 0;
  isAllDay: boolean = false;
  recurring: boolean = false; // 含 RRULE 或 RECURREIENCE-ID 的实例
  isTodo: boolean = false;    // VTODO 待办
  completed: boolean = false; // VTODO STATUS:COMPLETED
  rrule: string = '';         // 原始 RRULE
  exdate: string = '';        // 原始 EXDATE（分号分隔）
  reminder: number = 0;       // 主提醒提前分钟数（第一个提醒，兼容旧字段）
  reminders: number[] = [];   // 全部提醒提前分钟数（多选）
}

export class EventDb {
  private static db: relationalStore.RdbStore | null = null;

  static async getDb(context: common.Context): Promise<relationalStore.RdbStore> {
    if (EventDb.db !== null) {
      return EventDb.db;
    }
    const config: relationalStore.StoreConfig = {
      name: 'sync_calendar.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS events (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'uid TEXT, cal_key TEXT, href TEXT, remote_path TEXT, ' +
      'title TEXT, description TEXT, location TEXT, ' +
      'start_time INTEGER, end_time INTEGER, is_all_day INTEGER, ' +
      'etag TEXT, dirty INTEGER, deleted INTEGER, recurring INTEGER)'
    );
    // 旧版本库补列（已存在会抛错，忽略）
    try {
      await store.executeSql('ALTER TABLE events ADD COLUMN recurring INTEGER DEFAULT 0');
    } catch (err) {
      // 列已存在
    }
    try {
      await store.executeSql("ALTER TABLE events ADD COLUMN kind TEXT DEFAULT 'event'");
    } catch (err) {
      // 列已存在
    }
    try {
      await store.executeSql('ALTER TABLE events ADD COLUMN completed INTEGER DEFAULT 0');
    } catch (err) {
      // 列已存在
    }
    try {
      await store.executeSql("ALTER TABLE events ADD COLUMN rrule TEXT DEFAULT ''");
    } catch (err) {
      // 列已存在
    }
    try {
      await store.executeSql("ALTER TABLE events ADD COLUMN exdate TEXT DEFAULT ''");
    } catch (err) {
      // 列已存在
    }
    try {
      await store.executeSql('ALTER TABLE events ADD COLUMN reminder INTEGER DEFAULT 0');
    } catch (err) {
      // 列已存在
    }
    try {
      await store.executeSql("ALTER TABLE events ADD COLUMN reminders TEXT DEFAULT ''");
    } catch (err) {
      // 列已存在
    }
    EventDb.db = store;
    return store;
  }

  /** 提醒数组规范化：去掉 0/非法值并去重升序 */
  static normalizeReminders(list: number[]): number[] {
    const set = new Set<number>();
    for (const n of list) {
      if (n > 0) {
        set.add(n);
      }
    }
    return Array.from(set).sort((a: number, b: number): number => a - b);
  }

  /** 提醒数组比较键（规范化后逗号连接，用于增量比对） */
  static remKey(list: number[]): string {
    return EventDb.normalizeReminders(list).join(',');
  }

  private static fromRow(rs: relationalStore.ResultSet): LocalEvent {
    const e = new LocalEvent();
    e.id = rs.getLong(rs.getColumnIndex('id'));
    e.uid = rs.getString(rs.getColumnIndex('uid'));
    e.calKey = rs.getString(rs.getColumnIndex('cal_key'));
    e.href = rs.getString(rs.getColumnIndex('href'));
    e.remotePath = rs.getString(rs.getColumnIndex('remote_path'));
    e.title = rs.getString(rs.getColumnIndex('title'));
    e.description = rs.getString(rs.getColumnIndex('description'));
    e.location = rs.getString(rs.getColumnIndex('location'));
    e.startTime = rs.getLong(rs.getColumnIndex('start_time'));
    e.endTime = rs.getLong(rs.getColumnIndex('end_time'));
    e.isAllDay = rs.getLong(rs.getColumnIndex('is_all_day')) === 1;
    e.etag = rs.getString(rs.getColumnIndex('etag'));
    e.dirty = rs.getLong(rs.getColumnIndex('dirty')) === 1;
    e.deleted = rs.getLong(rs.getColumnIndex('deleted')) === 1;
    e.recurring = rs.getLong(rs.getColumnIndex('recurring')) === 1;
    const kind: string = rs.getString(rs.getColumnIndex('kind'));
    e.kind = kind === '' ? 'event' : kind;
    e.completed = rs.getLong(rs.getColumnIndex('completed')) === 1;
    e.rrule = rs.getString(rs.getColumnIndex('rrule'));
    e.exdate = rs.getString(rs.getColumnIndex('exdate'));
    e.reminder = rs.getLong(rs.getColumnIndex('reminder'));
    // 多提醒（逗号分隔分钟数）；旧数据无该列时回退单提醒
    const remStr: string = rs.getString(rs.getColumnIndex('reminders'));
    if (remStr !== '') {
      e.reminders = remStr.split(',').map((s: string): number => Number(s))
        .filter((n: number): boolean => !Number.isNaN(n) && n > 0);
    } else if (e.reminder > 0) {
      e.reminders = [e.reminder];
    }
    return e;
  }

  private static toBucket(e: LocalEvent): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {
      'uid': e.uid,
      'cal_key': e.calKey,
      'href': e.href,
      'remote_path': e.remotePath,
      'title': e.title,
      'description': e.description,
      'location': e.location,
      'start_time': e.startTime,
      'end_time': e.endTime,
      'is_all_day': e.isAllDay ? 1 : 0,
      'etag': e.etag,
      'dirty': e.dirty ? 1 : 0,
      'deleted': e.deleted ? 1 : 0,
      'recurring': e.recurring ? 1 : 0,
      'kind': e.kind,
      'completed': e.completed ? 1 : 0,
      'rrule': e.rrule,
      'exdate': e.exdate,
      'reminder': e.reminders.length > 0 ? e.reminders[0] : 0,
      'reminders': e.reminders.map((n: number): string => String(n)).join(',')
    };
    return bucket;
  }

  /** 新建本地事件 */
  static async insertLocal(context: common.Context, e: LocalEvent): Promise<number> {
    const store = await EventDb.getDb(context);
    e.dirty = true;
    const rowId = await store.insert('events', EventDb.toBucket(e));
    return rowId;
  }

  /** 更新本地事件（置 dirty 待推送） */
  static async updateLocal(context: common.Context, e: LocalEvent): Promise<void> {
    const store = await EventDb.getDb(context);
    e.dirty = true;
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', e.id);
    await store.update(EventDb.toBucket(e), predicates);
  }

  /** 标记删除（待推送 DELETE） */
  static async markDeleted(context: common.Context, id: number): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = { 'deleted': 1, 'dirty': 1 };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    await store.update(bucket, predicates);
  }

  /** 推送成功后清除 dirty（可回写 etag） */
  static async clearDirty(context: common.Context, id: number, etag: string): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = { 'dirty': 0, 'etag': etag };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    await store.update(bucket, predicates);
  }

  /** 推送删除成功后物理删除 */
  static async purge(context: common.Context, id: number): Promise<void> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    await store.delete(predicates);
  }

  /** 所有待推送事件 */
  static async getDirty(context: common.Context): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('dirty', 1);
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }
    return list;
  }

  /** 查询时间区间内未删除的日程（排除待办，待办单独展示） */
  static async queryRange(context: common.Context, start: number, end: number): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('deleted', 0).and().equalTo('kind', 'event')
      .and().lessThanOrEqualTo('start_time', end)
      .and().greaterThanOrEqualTo('end_time', start);
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }
    return list;
  }

  /** 单个事件 */
  static async getById(context: common.Context, id: number): Promise<LocalEvent | null> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    const rs = await store.query(predicates);
    let result: LocalEvent | null = null;
    try {
      if (rs.goToNextRow()) {
        result = EventDb.fromRow(rs);
      }
    } finally {
      rs.close();
    }
    return result;
  }

  /** 全部未删除的待办（VTODO），未完成在前、按截止时间升序 */
  static async queryTodos(context: common.Context): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('deleted', 0).and().equalTo('kind', 'todo');
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }
    list.sort((a: LocalEvent, b: LocalEvent): number => {
      if (a.completed !== b.completed) {
        return a.completed ? 1 : -1;
      }
      return a.startTime - b.startTime;
    });
    return list;
  }

  /** 全部重复主事件（有 RRULE 且开始时间在 before 之前，用于跨窗口展开） */
  static async queryRecurringMasters(context: common.Context, before: number): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('deleted', 0).and().equalTo('kind', 'event')
      .and().notEqualTo('rrule', '').and().lessThanOrEqualTo('start_time', before);
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }
    return list;
  }

  /** 未来 7 天内需要提醒的日程（reminder > 0），按开始时间升序 */
  static async queryRemindable(context: common.Context, from: number, to: number): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('deleted', 0).and().equalTo('kind', 'event')
      .and().greaterThan('reminder', 0)
      .and().greaterThanOrEqualTo('start_time', from)
      .and().lessThanOrEqualTo('start_time', to)
      .orderByAsc('start_time').limitAs(50);
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }
    return list;
  }

  /**
   * 用远端数据刷新某个日历本（增量）：
   * - etag 未变的跳过；变化的更新；远端没有的本地图删掉（排除本地待推送的新事件）
   * - 返回统计描述："新增X 更新Y 删除Z 不变W"
   */
  static async applyRemote(context: common.Context, calKey: string, href: string,
    remote: RemoteEvent[], isTodo: boolean): Promise<string> {
    const store = await EventDb.getDb(context);
    const kind: string = isTodo ? 'todo' : 'event';
    let added: number = 0;
    let updated: number = 0;
    let removed: number = 0;
    let unchanged: number = 0;
    // 读取该日历本当前所有行（仅同类型）
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('kind', kind);
    const rs = await store.query(predicates);
    const existing: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        existing.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }

    const remoteKeys: string[] = [];
    for (const r of remote) {
      // 重复日程实例共享 UID，唯一标识 = uid + 开始时间
      const key: string = `${r.uid}_${r.startTime}`;
      remoteKeys.push(key);
      const found = existing.find((x: LocalEvent): boolean =>
        !x.dirty && x.uid === r.uid && x.startTime === r.startTime);
      if (found === undefined) {
        // 新增
        const e = new LocalEvent();
        e.uid = r.uid;
        e.calKey = calKey;
        e.href = href;
        e.remotePath = encodeURIComponent(r.uid) + '.ics';
        e.title = r.title;
        e.description = r.description;
        e.location = r.location;
        e.startTime = r.startTime;
        e.endTime = r.endTime;
        e.isAllDay = r.isAllDay;
        e.etag = r.etag;
        e.dirty = false;
        e.deleted = false;
        e.recurring = r.recurring;
        e.kind = kind;
        e.completed = r.completed;
        e.rrule = r.rrule;
        e.exdate = r.exdate;
        e.reminder = r.reminder;
        e.reminders = r.reminders;
        await store.insert('events', EventDb.toBucket(e));
        added++;
      } else if (found.etag !== r.etag || found.rrule !== r.rrule || found.exdate !== r.exdate
        || found.reminder !== r.reminder || found.recurring !== r.recurring
        || EventDb.remKey(found.reminders) !== EventDb.remKey(r.reminders)) {
        // 更新（rrule/exdate/recurring 变化也更新，兼容老数据回填）
        found.title = r.title;
        found.description = r.description;
        found.location = r.location;
        found.startTime = r.startTime;
        found.endTime = r.endTime;
        found.isAllDay = r.isAllDay;
        found.etag = r.etag;
        found.dirty = false;
        found.deleted = false;
        found.recurring = r.recurring;
        found.kind = kind;
        found.completed = r.completed;
        found.rrule = r.rrule;
        found.exdate = r.exdate;
        found.reminder = r.reminder;
        found.reminders = r.reminders;
        const up = new relationalStore.RdbPredicates('events');
        up.equalTo('id', found.id);
        await store.update(EventDb.toBucket(found), up);
        updated++;
      } else {
        unchanged++;
      }
    }
    // 删除远端已不存在的（排除本地修改未推送的）
    for (const local of existing) {
      if (local.dirty) {
        continue;
      }
      const localKey: string = `${local.uid}_${local.startTime}`;
      if (!remoteKeys.includes(localKey)) {
        const del = new relationalStore.RdbPredicates('events');
        del.equalTo('id', local.id);
        await store.delete(del);
        removed++;
      }
    }
    return `新增${added} 更新${updated} 删除${removed} 不变${unchanged}`;
  }

  /** 查询某日历本下同类型的全部行（同步 etag 比对用，含 dirty 行） */
  static async queryByCalKey(context: common.Context, calKey: string, kind: string): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('kind', kind);
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(EventDb.fromRow(rs));
      }
    } finally {
      rs.close();
    }
    return list;
  }

  /** 按 UID 判断事件是否已存在（系统日历备份导入的幂等判重） */
  static async uidExists(context: common.Context, uid: string): Promise<boolean> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('uid', uid);
    const rs = await store.query(predicates);
    const exists: boolean = rs.rowCount > 0;
    rs.close();
    return exists;
  }

  /** 删除某账号全部本地事件（删除账号时调用） */
  static async deleteAccountEvents(context: common.Context, accId: string): Promise<void> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.like(`cal_key`, `${accId}%`);
    await store.delete(predicates);
  }

  /**
   * 清理孤儿行：calKey 既不是本机日历（local）、也不属于任何现有账号（accId_ 前缀）的历史残留数据。
   * 典型来源：账号删除重建、日历重选后序号变化遗留的旧 calKey（如 `_13`、`acc1789274273124_0_13`）。
   * 这些行会参与重复日程的 override 排除计算，导致重复日程的第一次发生不显示，必须物理删除。
   * 匹配规则为前缀包含（NOT LIKE 'accId_%' 的 AND 组合），宁可少删不会误删有效数据。
   */
  static async pruneOrphanCalKeys(context: common.Context, accIds: string[]): Promise<number> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.notEqualTo('cal_key', 'local');
    for (const id of accIds) {
      if (id === '') {
        continue;
      }
      predicates.and().notLike('cal_key', `${id}_%`);
    }
    const removed: number = await store.delete(predicates);
    return removed;
  }

  /**
   * 重新勾选日历本后清理失效数据：
   * 删除该账号下 calKey 不在有效列表中的本地日程/待办（calKey = accId_序号，重选后序号会变）
   */
  static async pruneAccountEvents(context: common.Context, accId: string,
    validCalKeys: string[]): Promise<void> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.like('cal_key', `${accId}_%`);
    if (validCalKeys.length > 0) {
      predicates.and().notIn('cal_key', validCalKeys);
    }
    await store.delete(predicates);
  }
}