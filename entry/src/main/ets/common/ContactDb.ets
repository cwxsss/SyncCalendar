// entry/src/main/ets/common/ContactDb.ets
// 本地联系人缓存（relationalStore）
//
// 为什么单独建库而不复用 EventDb：
//   联系人（vCard）与日程（iCalendar）的字段结构、同步语义、生命周期都不同。
//   塞进 events 表需要海量可空列，且会让已有的日程查询全部变慢、变复杂。
//   单独一个库文件更干净，卸载时也便于整体清除。
//
// 与 EventDb 一致的约定：
//   - dirty=1 表示本地改过、待推送；deleted=1 表示本地删除、待推送
//   - etag 用于"没变化就不重新解析"
//   - raw 存完整 vCard 原文 —— 回写时在原文上改字段，避免丢未建模属性
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { VCardContact, VCardPhone, VCardEmail, VCardUtil } from './VCardUtil';
import { LogUtil } from './LogUtil';

/** 库内一行联系人 */
export class ContactRow {
  id: number = 0;
  uid: string = '';
  bookKey: string = '';
  href: string = '';
  etag: string = '';
  displayName: string = '';
  org: string = '';
  title: string = '';
  note: string = '';
  /** 电话/邮箱以 JSON 数组字符串存在一行里 —— 联系人不会按电话单独查询，无需拆表 */
  phonesJson: string = '';
  emailsJson: string = '';
  /** 原始 vCard 全文 */
  raw: string = '';
  dirty: number = 0;
  deleted: number = 0;
  /** 系统通讯录里的联系人 key（镜像/双向同步用），空表示未关联 */
  sysKey: string = '';
  rev: string = '';
}

const DB_NAME: string = 'sync_contacts.db';
const TABLE: string = 'contacts';
const META: string = 'contact_meta';

/**
 * ⭐ 解析器版本号。
 *
 * 为什么需要（2026-11-11 实测踩到）：
 *   同步靠 ETag 判断"远端没变就跳过解析"。但**本地解析逻辑升级时 ETag 不会变**，
 *   于是旧数据永远停在旧解析结果上。
 *   实例：修好「ORG 值含 \; 被截断」后重同步，日志显示
 *        「远端 8，新增 0，更新 0，不变 8」 ← 根本没重新解析，界面还是错的。
 *
 * ⇒ 解析逻辑有任何影响输出结果的改动，就把这个数字 +1。
 *   启动时会比对，不一致就清空本地联系人缓存并强制全量重解析。
 */
const PARSER_VERSION: number = 2;

export class ContactDb {
  private static db: relationalStore.RdbStore | null = null;

  static async getDb(context: common.Context): Promise<relationalStore.RdbStore> {
    if (ContactDb.db !== null) {
      return ContactDb.db;
    }
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS contacts (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'uid TEXT, book_key TEXT, href TEXT, etag TEXT, ' +
      'display_name TEXT, org TEXT, title TEXT, note TEXT, ' +
      'phones_json TEXT, emails_json TEXT, raw TEXT, ' +
      'dirty INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0, ' +
      'sys_key TEXT, rev TEXT)'
    );
    // 唯一索引：同一地址簿内 uid 唯一。用 book_key+uid 而不是全局 uid，
    // 因为不同服务器可能给出相同 uid（尤其从别处导入的地址簿）。
    try {
      await store.executeSql(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_contacts_book_uid ON contacts(book_key, uid)'
      );
      await store.executeSql(
        'CREATE INDEX IF NOT EXISTS idx_contacts_syskey ON contacts(sys_key)'
      );
    } catch (err) {
      LogUtil.write(`创建联系人索引失败（忽略）：${(err as Error).message}`);
    }
    // 解析器版本表（单行）
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS contact_meta (k TEXT PRIMARY KEY, v TEXT)'
    );
    await ContactDb.checkParserVersion(store);
    ContactDb.db = store;
    return store;
  }

  /**
   * 解析器版本比对。不一致 ⇒ 清空联系人缓存，逼下一轮全量重解析。
   * 只清联系人数据（不动账号与设置），代价可控。
   */
  private static async checkParserVersion(store: relationalStore.RdbStore): Promise<void> {
    const want: string = String(PARSER_VERSION);
    try {
      const pred = new relationalStore.RdbPredicates(META);
      pred.equalTo('k', 'parser_version');
      const rs = await store.query(pred);
      let cur: string = '';
      try {
        if (rs.goToFirstRow()) {
          cur = rs.getString(rs.getColumnIndex('v'));
        }
      } finally {
        rs.close();
      }
      if (cur === want) {
        return;
      }
      // 版本不同 → 全清，等下一轮同步重新解析
      await store.executeSql('DELETE FROM ' + TABLE);
      // ⚠️ 不用 update-then-insert：update 影响 0 行时插入会撞主键
      //    （实测报 "Abort due to constraint violation"）。
      //    直接 INSERT OR REPLACE 一步到位。
      await store.executeSql(
        `INSERT OR REPLACE INTO ${META} (k, v) VALUES ('parser_version', '${want}')`);
      LogUtil.write(`联系人解析器版本 ${cur === '' ? '(无)' : cur} → ${want}，已清空缓存待重解析`);
    } catch (err) {
      LogUtil.write(`联系人解析器版本检查失败：${(err as Error).message}`);
    }
  }

  /** 把解析后的联系人写入/更新（按 book_key + uid 判断） */
  static async upsert(context: common.Context, c: VCardContact, bookKey: string,
    etag: string): Promise<void> {
    const store = await ContactDb.getDb(context);
    const phonesJson: string = JSON.stringify(c.phones.map((p): string => p.value));
    const emailsJson: string = JSON.stringify(c.emails.map((e): string => e.value));
    const existing: ContactRow | null = await ContactDb.findByUid(context, bookKey, c.uid);
    if (existing === null) {
      const values: relationalStore.ValuesBucket = {
        'uid': c.uid,
        'book_key': bookKey,
        'href': c.href,
        'etag': etag,
        'display_name': c.displayName,
        'org': c.org,
        'title': c.title,
        'note': c.note,
        'phones_json': phonesJson,
        'emails_json': emailsJson,
        'raw': c.raw,
        'dirty': 0,
        'deleted': 0,
        'sys_key': '',
        'rev': c.rev
      };
      await store.insert(TABLE, values);
    } else {
      const values: relationalStore.ValuesBucket = {
        'href': c.href,
        'etag': etag,
        'display_name': c.displayName,
        'org': c.org,
        'title': c.title,
        'note': c.note,
        'phones_json': phonesJson,
        'emails_json': emailsJson,
        'raw': c.raw,
        'deleted': 0,
        'rev': c.rev
      };
      const pred = new relationalStore.RdbPredicates(TABLE);
      pred.equalTo('id', existing.id);
      await store.update(values, pred);
    }
  }

  static async findByUid(context: common.Context, bookKey: string, uid: string): Promise<ContactRow | null> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('book_key', bookKey).and().equalTo('uid', uid);
    const rs = await store.query(pred);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return ContactDb.readRow(rs);
    } finally {
      rs.close();
    }
  }

  static async findByHref(context: common.Context, href: string): Promise<ContactRow | null> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('href', href);
    const rs = await store.query(pred);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return ContactDb.readRow(rs);
    } finally {
      rs.close();
    }
  }

  static async findById(context: common.Context, id: number): Promise<ContactRow | null> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('id', id);
    const rs = await store.query(pred);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return ContactDb.readRow(rs);
    } finally {
      rs.close();
    }
  }

  /** 列出所有未删除联系人（界面列表用），按显示名排序 */
  static async listAll(context: common.Context): Promise<ContactRow[]> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('deleted', 0);
    const rs = await store.query(pred, ['id', 'uid', 'book_key', 'href', 'etag',
      'display_name', 'org', 'title', 'note', 'phones_json', 'emails_json',
      'raw', 'dirty', 'deleted', 'sys_key', 'rev']);
    const out: ContactRow[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push(ContactDb.readRow(rs));
      }
    } finally {
      rs.close();
    }
    // 中文按 localeCompare 排序，拼音/笔画顺序由系统 locale 决定
    out.sort((a: ContactRow, b: ContactRow): number => a.displayName.localeCompare(b.displayName, 'zh'));
    return out;
  }

  static async count(context: common.Context): Promise<number> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('deleted', 0);
    const rs = await store.query(pred, ['id']);
    try {
      return rs.rowCount;
    } finally {
      rs.close();
    }
  }

  /** 标记为已删除（软删除，等被推送后才真删） */
  static async markDeleted(context: common.Context, id: number): Promise<void> {
    const store = await ContactDb.getDb(context);
    const values: relationalStore.ValuesBucket = { 'deleted': 1, 'dirty': 1 };
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('id', id);
    await store.update(values, pred);
  }

  /** 远端已不存在的资源 → 直接从库中移除（不需要推送） */
  static async removeByHref(context: common.Context, href: string): Promise<void> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('href', href);
    await store.delete(pred);
  }

  /** 物理删除（推送成功或清理残留时） */
  static async hardDelete(context: common.Context, id: number): Promise<void> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('id', id);
    await store.delete(pred);
  }

  /** 带 dirty 标记的行（待推送） */
  static async listDirty(context: common.Context): Promise<ContactRow[]> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('dirty', 1);
    const rs = await store.query(pred);
    const out: ContactRow[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push(ContactDb.readRow(rs));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 更新原文与 etag（推送成功后回写） */
  static async setRawAndClean(context: common.Context, id: number, raw: string,
    etag: string): Promise<void> {
    const store = await ContactDb.getDb(context);
    const values: relationalStore.ValuesBucket = { 'raw': raw, 'etag': etag, 'dirty': 0 };
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('id', id);
    await store.update(values, pred);
  }

  /** 关联系统通讯录 key */
  static async setSysKey(context: common.Context, id: number, sysKey: string): Promise<void> {
    const store = await ContactDb.getDb(context);
    const values: relationalStore.ValuesBucket = { 'sys_key': sysKey };
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('id', id);
    await store.update(values, pred);
  }

  /** 按系统通讯录 key 反查（系统侧删除时用） */
  static async findBySysKey(context: common.Context, sysKey: string): Promise<ContactRow | null> {
    if (sysKey === '') {
      return null;
    }
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('sys_key', sysKey);
    const rs = await store.query(pred);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return ContactDb.readRow(rs);
    } finally {
      rs.close();
    }
  }

  /** 清空指定地址簿（重新全量同步前用） */
  static async clearBook(context: common.Context, bookKey: string): Promise<void> {
    const store = await ContactDb.getDb(context);
    const pred = new relationalStore.RdbPredicates(TABLE);
    pred.equalTo('book_key', bookKey);
    await store.delete(pred);
  }

  private static readRow(rs: relationalStore.ResultSet): ContactRow {
    const r = new ContactRow();
    r.id = rs.getLong(rs.getColumnIndex('id'));
    r.uid = rs.getString(rs.getColumnIndex('uid'));
    r.bookKey = rs.getString(rs.getColumnIndex('book_key'));
    r.href = rs.getString(rs.getColumnIndex('href'));
    r.etag = rs.getString(rs.getColumnIndex('etag'));
    r.displayName = rs.getString(rs.getColumnIndex('display_name'));
    r.org = rs.getString(rs.getColumnIndex('org'));
    r.title = rs.getString(rs.getColumnIndex('title'));
    r.note = rs.getString(rs.getColumnIndex('note'));
    r.phonesJson = rs.getString(rs.getColumnIndex('phones_json'));
    r.emailsJson = rs.getString(rs.getColumnIndex('emails_json'));
    r.raw = rs.getString(rs.getColumnIndex('raw'));
    r.dirty = rs.getLong(rs.getColumnIndex('dirty'));
    r.deleted = rs.getLong(rs.getColumnIndex('deleted'));
    r.sysKey = rs.getString(rs.getColumnIndex('sys_key'));
    r.rev = rs.getString(rs.getColumnIndex('rev'));
    return r;
  }

  // ───────────── 便捷转换 ─────────────

  /** ContactRow → 本地模型（列表展示与编辑用） */
  static toModel(r: ContactRow): VCardContact {
    const c = new VCardContact();
    c.uid = r.uid;
    c.href = r.href;
    c.etag = r.etag;
    c.displayName = r.displayName;
    c.org = r.org;
    c.title = r.title;
    c.note = r.note;
    c.raw = r.raw;
    c.rev = r.rev;
    c.phones = ContactDb.parsePhones(r.phonesJson);
    c.emails = ContactDb.parseEmails(r.emailsJson);
    return c;
  }

  private static parsePhones(json: string): VCardPhone[] {
    const out: VCardPhone[] = [];
    if (json === '') {
      return out;
    }
    try {
      const arr = JSON.parse(json) as string[];
      for (const v of arr) {
        const p = new VCardPhone();
        p.value = v;
        out.push(p);
      }
    } catch (err) {
      LogUtil.write(`解析电话列表失败：${(err as Error).message}`);
    }
    return out;
  }

  private static parseEmails(json: string): VCardEmail[] {
    const out: VCardEmail[] = [];
    if (json === '') {
      return out;
    }
    try {
      const arr = JSON.parse(json) as string[];
      for (const v of arr) {
        const e = new VCardEmail();
        e.value = v;
        out.push(e);
      }
    } catch (err) {
      LogUtil.write(`解析邮箱列表失败：${(err as Error).message}`);
    }
    return out;
  }
}