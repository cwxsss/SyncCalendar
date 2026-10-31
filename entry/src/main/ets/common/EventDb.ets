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
  /** ⭐ RECURRENCE-ID：本行"覆盖"的是主事件的哪一次发生（毫秒，0 = 无/旧数据未回填）。
   *  只改标题时它等于 startTime；**把某次发生改期**时它才是原始时刻——
   *  排除主事件对应发生时必须用它，否则原时间会残留成"幽灵日程"。 */
  recurrenceId: number = 0;
  reminder: number = 0;     // 主提醒提前分钟数（第一个提醒，兼容旧字段），0 = 不提醒
  reminders: number[] = []; // 全部提醒提前分钟数（多选），按添加顺序
}

/** 远端事件条目（REPORT 解析结果） */
export class RemoteEvent {
  uid: string = '';
  remotePath: string = '';
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
  recurrenceId: number = 0;   // 原始 RECURRENCE-ID（毫秒；0 = 无）
  reminder: number = 0;       // 主提醒提前分钟数（第一个提醒，兼容旧字段）
  reminders: number[] = [];   // 全部提醒提前分钟数（多选）
}

export class EventDb {
  private static db: relationalStore.RdbStore | null = null;

  /**
   * ⭐ 统计"是覆盖实例（RECURRENCE-ID 行）但还没回填 recurrence_id"的行数。
   *
   * 语义：`recurring=1 且 rrule=''` ⟺ 这一行的 .ics 里有 RECURRENCE-ID。
   * 老库升级后这些行的 recurrence_id 一律是 0（字段以前被丢弃，无法从本地反推），
   * 必须靠一次全量重拉（GET 每个 .ics）才能填上。
   * **用数据本身当标志，而不是内存变量** —— 卡片进程/进程重启会把内存标志吃掉
   *（实测 2026-09-19 18:30/18:36 两次同步都没触发全量重拉）。
   * 回填完成后返回值自然变 0，不会反复触发。
   */
  static async countOverridesMissingRecurrenceId(context: common.Context): Promise<number> {
    try {
      const store = await EventDb.getDb(context);
      const rs = await store.querySql(
        "select count(*) c from events " +
        "where deleted = 0 and recurring = 1 and rrule = '' and recurrence_id = 0");
      let n: number = 0;
      try {
        if (rs.goToNextRow()) {
          n = rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
      return n;
    } catch (err) {
      return 0;
    }
  }

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
    // ⭐ 覆盖实例的"原始发生时刻"（RECURRENCE-ID）。老库升级后该列一律为 0，需要一次全量重拉回填
    try {
      await store.executeSql('ALTER TABLE events ADD COLUMN recurrence_id INTEGER DEFAULT 0');
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

  /**
   * ⭐ 覆盖实例（RECURRENCE-ID 独立行）"排除主事件哪一次发生"用的键。
   *
   * 必须优先用 **recurrenceId**（原始发生时刻）：覆盖行的 startTime 是**被改到的新时间**，
   * 用它做键时主事件在**原时间**的那次发生不会被排除 → App 与系统日历里同一日程出现两条
   * （2026-09-19 真机实测：窗口内 63 条这种"幽灵日程"）。
   * recurrenceId = 0 表示旧库数据（还没回填）→ 回退到 startTime，保持老行为不变。
   */
  static overrideKey(calKey: string, uid: string, recurrenceId: number, startTime: number): string {
    return `${calKey}_${uid}_${recurrenceId > 0 ? recurrenceId : startTime}`;
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
    e.recurrenceId = rs.getLong(rs.getColumnIndex('recurrence_id'));
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
      'recurrence_id': e.recurrenceId,
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
   * - 实例唯一键用 `${uid}_${startTime}`：同一 uid 的多日展开各自成行，
   *   因此**改期会表现为"旧实例删除 + 新实例新增"**，属预期行为。
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

    // ⭐ 2226（2026-10-15 提速）：下方逐条要判"这条远端事件本地有没有对应行"。
    //    原先对每条都 `existing.find(...)` ⇒ O(n·m)（工作本 735 行 → 54 万次比较，
    //    每次还要现拼 `uid_startTime_recId` 字符串），2184 行全库累计近 100 万次。
    //    卡片后台同步的时间预算只有 9 秒，这笔开销吃不起 → 预先建 Map，改成 O(1) 查。
    //    语义与 `existing.find(x => !x.dirty && x.uid===r.uid && x.startTime===r.startTime
    //    && x.recurrenceId===r.recurrenceId)` 完全一致：dirty 行不入索引、同键取**最先**出现的那行。
    const keyed: Map<string, LocalEvent> = new Map<string, LocalEvent>();
    const dirtyDeletedUids: Set<string> = new Set<string>();
    const dirtyKeyed: Map<string, LocalEvent> = new Map<string, LocalEvent>();
    for (const e of existing) {
      if (e.dirty && e.deleted) {
        dirtyDeletedUids.add(e.uid);
      }
      const k: string = `${e.uid}_${e.startTime}_${e.recurrenceId}`;
      if (e.dirty) {
        if (!dirtyKeyed.has(k)) {
          dirtyKeyed.set(k, e);
        }
        continue;
      }
      if (!keyed.has(k)) {
        keyed.set(k, e);
      }
    }
    // ⭐ 同一次解析里可能出现同一资源的多条相同 VEVENT（同 uid + 同 DTSTART）。
    //    旧版用循环前的 existing 快照判重，插入后不回写 → 第二条仍判为"新增"又插一行，
    //    在本地库留下 href/etag/remote_path 完全相同的冗余行（2026-09-19 实测 10 组）。
    const seenKeys: Set<string> = new Set<string>();
    for (const r of remote) {
      // 重复日程实例共享 UID，唯一标识 = uid + 开始时间 + RECURRENCE-ID
      //（同一时刻可能同时存在"主事件"与"覆盖该次发生的实例行"，只带上 recurrenceId 才唯一）
      const key: string = `${r.uid}_${r.startTime}_${r.recurrenceId}`;
      if (seenKeys.has(key)) {
        continue; // 同一资源内的重复条目 → 只保留一条
      }
      seenKeys.add(key);
      if (dirtyDeletedUids.has(r.uid)) {
        continue; // 本地刚被用户删除待推送，忽略远端旧版本，防止被死灰复燃
      }
      if (dirtyKeyed.has(key)) {
        // 本地该事件有修改待推送，保留本地版本，忽略远端旧版本，绝不能作为新事件重复插入
        continue;
      }
      const found: LocalEvent | undefined = keyed.get(key);
      if (found === undefined) {
        // 新增
        const e = new LocalEvent();
        e.uid = r.uid;
        e.calKey = calKey;
        e.href = href;
        e.remotePath = r.remotePath !== '' ? r.remotePath : (encodeURIComponent(r.uid) + '.ics');
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
        e.recurrenceId = r.recurrenceId;
        e.reminder = r.reminder;
        e.reminders = r.reminders;
        await store.insert('events', EventDb.toBucket(e));
        added++;
      } else if (found.etag !== r.etag || found.rrule !== r.rrule || found.exdate !== r.exdate
        || found.reminder !== r.reminder || found.recurring !== r.recurring
        || EventDb.remKey(found.reminders) !== EventDb.remKey(r.reminders)
        || found.href !== href) {
        // 更新（rrule/exdate/recurring 变化也更新，兼容老数据回填；
        // href 变化也要更新——服务器上日历本被删除重建后集合 URL 变了，
        // 行里若残留旧 URL，用户下次编辑该日程会 PUT 到已不存在的集合（404），
        // 且 pushDirty 按 href 过滤会漏掉它导致永远推不出去）
        found.href = href;
        if (r.remotePath !== '' && found.remotePath !== r.remotePath) {
          found.remotePath = r.remotePath;
        }
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
        found.recurrenceId = r.recurrenceId;
        found.reminder = r.reminder;
        found.reminders = r.reminders;
        const up = new relationalStore.RdbPredicates('events');
        up.equalTo('id', found.id);
        await store.update(EventDb.toBucket(found), up);
        updated++;
      } else {
        unchanged++;
        // etag 未变也要校正 href：日历本被删除重建后集合 URL 变化，etag 比对仍然全部命中，
        // 不在这里刷新的话旧 URL 会一直残留在行上（见上方更新分支的注释）
        if (found.href !== href) {
          found.href = href;
          const hp = new relationalStore.RdbPredicates('events');
          hp.equalTo('id', found.id);
          const hb: relationalStore.ValuesBucket = { 'href': href };
          await store.update(hb, hp);
        }
      }
    }
    // 删除远端已不存在的（排除本地修改未推送的）
    for (const local of existing) {
      if (local.dirty) {
        continue;
      }
      const localKey: string = `${local.uid}_${local.startTime}_${local.recurrenceId}`;
      // ⭐ 同样从 O(m) 的数组 includes 换成 Set 查询（见上方 keyed 的说明）
      if (!seenKeys.has(localKey)) {
        const del = new relationalStore.RdbPredicates('events');
        del.equalTo('id', local.id);
        await store.delete(del);
        removed++;
      }
    }
    return `新增${added} 更新${updated} 删除${removed} 不变${unchanged}`;
  }

  /**
   * 清理"同一资源"的冗余重复行（**纯本地去重，绝不触碰服务器**）。
   *
   * 起因：旧版 applyRemote 用循环前的一次性 existing 快照判重，同一个 .ics 里若含
   * 多条相同 (UID, DTSTART) 的 VEVENT，第二条仍被判为"新增"再插一行 →
   * 本地库出现 href / etag / remote_path 完全相同的重复行（2026-09-19 实测 10 组）。
   * 影响：① App 里同一日程显示两条；② 镜像到系统日历后同一 identifier 互相覆盖，
   *      出现"计划 984 条、系统只写出 983 条"的口径差。
   *
   * 口径：同 (cal_key, uid, start_time, recurrence_id) 且在**同一资源**（href 非空）下，
   * 只保留 id 最小的一行。
   * 含本地未推送修改（dirty=1）的行整个不参与，绝不会连带删掉待推送数据。
   * 被删行**不置 dirty/deleted**，因此不会向服务器推送任何删除。
   * ⚠️ 分组必须带上 recurrence_id：主事件与"覆盖该次发生的实例行"可能同 uid 同 start_time，
   *    它们是两条**合法**的不同发生，不能被当成冗余行删掉。
   * @returns 删除的冗余行数
   */
  static async dedupeDuplicateRows(context: common.Context): Promise<number> {
    let removed: number = 0;
    try {
      const store = await EventDb.getDb(context);
      // 只处理"远端资源、已删标记为 0、且没有本地未推送修改（dirty=0）"的行。
      // 某个组里只要有一行是 dirty，它就不参与分组 → 组内只剩 1 行 → count(*)>1 不成立 → 不动。
      // 这样绝不会把"待推送的本地修改"连带删掉。
      const rs = await store.querySql(
        "select group_concat(id) ids from events " +
        "where deleted = 0 and dirty = 0 and href <> '' " +
        "group by cal_key, uid, start_time, recurrence_id having count(*) > 1");
      const groups: string[] = [];
      try {
        while (rs.goToNextRow()) {
          const v: string = rs.getString(rs.getColumnIndex('ids'));
          if (v !== undefined && v !== null && v !== '') {
            groups.push(v);
          }
        }
      } finally {
        rs.close();
      }
      for (const g of groups) {
        const ids: number[] = g.split(',')
          .map((s: string): number => Number(s.trim()))
          .filter((n: number): boolean => !Number.isNaN(n));
        ids.sort((a: number, b: number): number => a - b);
        for (let i: number = 1; i < ids.length; i++) { // 0 号（最小 id）保留
          const del = new relationalStore.RdbPredicates('events');
          del.equalTo('id', ids[i]);
          await store.delete(del);
          removed++;
        }
      }
    } catch (err) {
      // 去重失败不影响主流程
      return removed;
    }
    return removed;
  }

  /** 查询某日历本下同类型的全部行（同步 etag 比对用，含 dirty 行）
   *  ⭐ 固定按 id 升序：镜像/展示遇到"同 uid 多行"时谁先谁后必须稳定，
   *  否则同一 identifier 每次换一行 → 系统日历在两处之间反复翻转（实测过）。 */
  static async queryByCalKey(context: common.Context, calKey: string, kind: string): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('kind', kind);
    predicates.orderByAsc('id');
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
   * ⭐ 取同一个 UID 在同一个日历本下的**全部行**（主事件 + 覆盖实例）。
   * 用于"重复日程的单次/后续/全部"编辑与删除：重建整个系列后一次性推送。
   * @param includeDeleted 是否包含被标记删除（deleted=1）的行
   */
  static async queryByUid(context: common.Context, calKey: string, uid: string,
    includeDeleted: boolean = false): Promise<LocalEvent[]> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', uid);
    predicates.orderByAsc('id');
    const rs = await store.query(predicates);
    const list: LocalEvent[] = [];
    try {
      while (rs.goToNextRow()) {
        const e = EventDb.fromRow(rs);
        if (includeDeleted || !e.deleted) {
          list.push(e);
        }
      }
    } finally {
      rs.close();
    }
    return list;
  }

  /** 获取某 uid 的主事件（优先带 rrule 的行，无则最早一行） */
  static async getMasterByUid(context: common.Context, calKey: string, uid: string): Promise<LocalEvent | null> {
    const rows: LocalEvent[] = await EventDb.queryByUid(context, calKey, uid);
    for (const r of rows) {
      if (r.rrule !== '') {
        return r;
      }
    }
    return rows.length > 0 ? rows[0] : null;
  }

  /** 将某个 UID 下的所有行（整系列：主事件与所有覆盖行）标记删除 */
  static async markDeletedByUid(context: common.Context, calKey: string, uid: string): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = { 'deleted': 1, 'dirty': 1 };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', uid);
    await store.update(bucket, predicates);
  }

  /** 物理删除某 uid 在某个日历本下的全部行（"删除全部"用） */
  static async purgeByUid(context: common.Context, calKey: string, uid: string): Promise<number> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', uid);
    return await store.delete(predicates);
  }

  /** 物理删除某 uid 在某个日历本下、开始时间 >= from 的全部行（"此次及以后"删除用） */
  static async purgeByUidFrom(context: common.Context, calKey: string, uid: string,
    from: number): Promise<number> {
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', uid)
      .and().greaterThanOrEqualTo('start_time', from);
    return await store.delete(predicates);
  }

  /**
   * ⭐ 把某个 uid 系列下、开始时间 >= from 的行搬到另一个 uid（"此次及以后"改期的实现）：
   * 主事件被截断（加 UNTIL）后，剩余部分作为**新的独立系列**存在，否则会被原系列覆盖。
   * 返回被搬迁的行数。
   */
  static async reassignUidFrom(context: common.Context, calKey: string, oldUid: string,
    newUid: string, newPath: string, from: number): Promise<number> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = {
      'uid': newUid,
      'remote_path': newPath,
      'etag': '',
      'dirty': 1
    };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', oldUid)
      .and().greaterThanOrEqualTo('start_time', from);
    return await store.update(bucket, predicates);
  }

  /** 给单行写入 EXDATE（"仅删除这一次"→ 排除主事件的该次发生） */
  static async setExdate(context: common.Context, id: number, exdate: string): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = { 'exdate': exdate, 'dirty': 1 };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    await store.update(bucket, predicates);
  }

  /**
   * ⭐ 把某 uid 系列下、**RECURRENCE-ID >= from** 的覆盖实例行搬到新 uid
   * （"此次及以后"拆分系列时用；主事件行 recurrenceId=0，天然不会被命中）。
   */
  static async reassignOverridesFrom(context: common.Context, calKey: string, oldUid: string,
    newUid: string, newPath: string, from: number): Promise<number> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = {
      'uid': newUid,
      'remote_path': newPath,
      'etag': '',
      'dirty': 1
    };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', oldUid)
      .and().greaterThanOrEqualTo('recurrence_id', from);
    return await store.update(bucket, predicates);
  }

  /**
   * ⭐ 给某个 uid 系列（指定日历本）的主事件写入 RRULE（"此次及以后"截断/改期时用）。
   * 只作用于有 RRULE 的主事件行。
   */
  static async setRruleForUid(context: common.Context, calKey: string, uid: string,
    rrule: string): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = { 'rrule': rrule, 'dirty': 1 };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('cal_key', calKey).and().equalTo('uid', uid)
      .and().notEqualTo('rrule', '');
    await store.update(bucket, predicates);
  }

  /** 新增一行（供拆分系列时插入新主事件；已置 dirty） */
  static async insertRow(context: common.Context, e: LocalEvent): Promise<number> {
    return await EventDb.insertLocal(context, e);
  }

  /**
   * ⭐ 用一份原始快照**还原**某一行的内容（仅内容字段，不动 id）。
   * 用途：编辑重复日程的"仅这一次 / 此次及以后"时，`doSave` 会把当前行就地写成新值，
   * 但该行属于"原系列"（被 EXDATE 排除或被 UNTIL 截断），必须还原，
   * 否则原系列里会残留一条被改过的幽灵行。
   */
  static async restoreRowById(context: common.Context, id: number, src: LocalEvent): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = {
      'title': src.title,
      'description': src.description,
      'location': src.location,
      'start_time': src.startTime,
      'end_time': src.endTime,
      'is_all_day': src.isAllDay ? 1 : 0,
      'rrule': src.rrule,
      'exdate': src.exdate,
      'recurrence_id': src.recurrenceId,
      'recurring': src.recurring ? 1 : 0,
      'reminder': src.reminders.length > 0 ? src.reminders[0] : src.reminder,
      'reminders': src.reminders.map((n: number): string => String(n)).join(','),
      'dirty': 1
    };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    await store.update(bucket, predicates);
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

  /**
   * 删除某账号下、属于指定日历本集合（按 href 匹配）的全部本地日程/待办。
   *
   * 用途：日历本在服务器上被删除（同步 REPORT 返回 404）或用户取消勾选时，
   * 必须在 calKey 序号迁移**之前**先删掉这些行——否则序号收窄后，被移除日历本的
   * 旧行会与新搬到该序号下的其它日历本行混在同一个 calKey 里（2026-09-29 实测：
   * 「读书」被服务器删除后重选，其 988 行混进「轻舟」的 calKey）。
   * 行上自带 href（日历本集合 URL），按 href 删比按 calKey 删更稳——
   * 历史原因（旧版迁移缺陷）行可能挂在错误的 calKey 下，href 才是行的真实归属。
   */
  static async pruneByHrefs(context: common.Context, accId: string, hrefs: string[]): Promise<number> {
    if (hrefs.length === 0) {
      return 0;
    }
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.like('cal_key', `${accId}_%`);
    predicates.and().in('href', hrefs);
    return await store.delete(predicates);
  }

  /**
   * 清理「href 已不属于任何已选日历本」的残留行（跨账号兜底清扫）。
   * 典型：服务器删除日历本后，旧版把其残留行混进其它日历本的 calKey（见 pruneByHrefs 注释），
   * 这类行 calKey 看似有效、pruneOrphanCalKeys 抓不到，但 href 暴露了真实归属。
   * ⚠️ 跳过 dirty 行（用户未推送的本地修改绝不能被清扫掉）与 local 行。
   */
  static async pruneStaleHrefs(context: common.Context, validHrefs: string[]): Promise<number> {
    if (validHrefs.length === 0) {
      return 0;
    }
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.notEqualTo('cal_key', 'local');
    predicates.and().notEqualTo('href', '');
    predicates.and().notIn('href', validHrefs);
    predicates.and().equalTo('dirty', 0);
    return await store.delete(predicates);
  }

  /**
   * 迁移因「日历本序号变动」而错位的日程行（calKey = `${accId}_${序号}`）。
   *
   * 背景（本方法要修的现象）：序号取自「勾选顺序」。在服务器上新增一个日历本后重新勾选，
   * 若新本不是排在末尾而是插在中间，其后所有日历本的序号都会 +1；但已落库的日程仍挂着
   * 旧 calKey，于是**日程与日历本错位**——表现为色块颜色不对、日程显示到别人的日历本下。
   * 同步虽然最终会用远端数据重建，但在同步完成前（以及同步部分失败时）错位一直可见。
   *
   * 做法：按 href 对应关系把旧 calKey 的行整体搬到新 calKey。
   * 分两阶段更新（旧键 → 临时键 → 新键），避免 A↔B 互换时后一次更新把前一次的行一起改掉。
   *
   * @param pairs [旧calKey, 新calKey] 列表；只传真正发生位移的项
   * @returns 被迁移的行数
   */
  static async remapCalKeys(context: common.Context, pairs: Array<[string, string]>): Promise<number> {
    if (pairs.length === 0) {
      return 0;
    }
    const store = await EventDb.getDb(context);
    const stamp: number = Date.now();
    const tmpKeys: string[] = [];
    let moved: number = 0;
    // 阶段一：旧键 → 临时键
    for (let i = 0; i < pairs.length; i++) {
      const tmpKey: string = `__remap_${stamp}_${i}`;
      const bucket: relationalStore.ValuesBucket = { 'cal_key': tmpKey };
      const p = new relationalStore.RdbPredicates('events');
      p.equalTo('cal_key', pairs[i][0]);
      moved += await store.update(bucket, p);
      tmpKeys.push(tmpKey);
    }
    // 阶段二：临时键 → 新键
    for (let i = 0; i < pairs.length; i++) {
      const bucket: relationalStore.ValuesBucket = { 'cal_key': pairs[i][1] };
      const p = new relationalStore.RdbPredicates('events');
      p.equalTo('cal_key', tmpKeys[i]);
      await store.update(bucket, p);
    }
    return moved;
  }

  /**
   * 更新待办完成状态并标记为 dirty 待推送
   */
  static async toggleTodoCompleted(context: common.Context, id: number, completed: boolean): Promise<void> {
    const store = await EventDb.getDb(context);
    const bucket: relationalStore.ValuesBucket = {
      'completed': completed ? 1 : 0,
      'dirty': 1
    };
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    await store.update(bucket, predicates);
  }

  /**
   * 全局搜索日程（按标题、地点、描述模糊匹配），排除已删除的行
   * @param keyword 关键词
   * @param limit 最多返回条数（默认 60）
   */
  static async search(context: common.Context, keyword: string, limit: number = 60): Promise<LocalEvent[]> {
    const trimmed = keyword.trim();
    if (trimmed === '') {
      return [];
    }
    const store = await EventDb.getDb(context);
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('deleted', 0)
      .and()
      .beginWrap()
      .like('title', '%' + trimmed + '%')
      .or()
      .like('location', '%' + trimmed + '%')
      .or()
      .like('description', '%' + trimmed + '%')
      .endWrap()
      .orderByDesc('start_time')
      .limitAs(limit);
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
}