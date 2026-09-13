// entry/src/main/ets/common/AccountStore.ets
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const TYPE_CALDAV: string = 'caldav';
export const TYPE_CARDDAV: string = 'carddav';
export const TYPE_WEBDAV: string = 'webdav';
export const TYPE_KEYS: string[] = [TYPE_CALDAV, TYPE_CARDDAV, TYPE_WEBDAV];

/** 本机事件所属的虚拟日历 key */
export const LOCAL_CAL_KEY: string = 'local';

/**
 * DAV 账号（@Observed 使同步状态变化能刷新列表 UI）
 */
@Observed
export class DavAccount {
  id: string = '';
  type: string = TYPE_CALDAV;
  name: string = '';
  serverUrl: string = '';
  username: string = '';
  password: string = '';
  calendarHrefs: string[] = [];
  calendarNames: string[] = [];
  /** 服务器端定义的日历本颜色（calendar-color），与 calendarHrefs 一一对应，空串表示未定义 */
  calendarColors: string[] = [];
  itemCount: number = 0;
  lastSyncTime: string = '';
}

/** 日历本来源（用于界面显隐与取色） */
export class CalSource {
  calKey: string = '';
  name: string = '';
  color: string = '#007DFF';
  source: string = 'dav'; // 'dav' | 'system' | 'local'
  visible: boolean = true;
}

/** 与 UI 无关的调色板 */
export class BookPalette {
  static colors: string[] = [
    '#007DFF', '#FF7D00', '#00B96B', '#9F44FF', '#F5317F', '#00B2C6', '#B58600', '#6D4AFF'
  ];
  static colorFor(index: number): string {
    return BookPalette.colors[index % BookPalette.colors.length];
  }
}

/**
 * 账号持久化：每个账号编码为一个分隔符字符串存储（acc_0、acc_1…），避免 JSON 结构化类型问题
 */
export class AccountStore {
  private static readonly STORE: string = 'caldav_account';
  private static readonly COUNT_KEY: string = 'accountCount';

  /** 规范化颜色：#RRGGBBAA → #RRGGBB；非法返回空串 */
  static normalizeColor(raw: string): string {
    const v: string = raw.trim();
    if (/^#[0-9A-Fa-f]{8}$/.test(v)) {
      return '#' + v.substring(3, 9);
    }
    if (/^#[0-9A-Fa-f]{6}$/.test(v)) {
      return v.toUpperCase();
    }
    return '';
  }

  private static encodeAccount(acc: DavAccount): string {
    const safe = (s: string): string => s.split('|').join('∥');
    const parts: string[] = [
      safe(acc.type),
      safe(acc.name),
      safe(acc.serverUrl),
      safe(acc.username),
      safe(acc.password),
      String(acc.itemCount),
      safe(acc.lastSyncTime),
      acc.calendarHrefs.join(';'),
      acc.calendarNames.join(';'),
      acc.calendarColors.join(';'),
      safe(acc.id)
    ];
    return parts.join('|');
  }

  private static decodeAccount(raw: string): DavAccount | null {
    const parts: string[] = raw.split('|');
    if (parts.length < 9) {
      return null;
    }
    const acc = new DavAccount();
    acc.type = parts[0] === '' ? TYPE_CALDAV : parts[0];
    acc.name = parts[1];
    acc.serverUrl = parts[2];
    acc.username = parts[3];
    acc.password = parts[4];
    const count: number = Number(parts[5]);
    acc.itemCount = Number.isNaN(count) ? 0 : count;
    acc.lastSyncTime = parts[6];
    acc.calendarHrefs = parts[7] === '' ? [] : parts[7].split(';');
    acc.calendarNames = parts[8] === '' ? [] : parts[8].split(';');
    if (parts.length >= 10) {
      acc.calendarColors = parts[9] === '' ? [] : parts[9].split(';');
    }
    // 兼容旧版本存储（无 id 字段）：加载时为空，由 loadAll 统一补发并持久化
    if (parts.length >= 11) {
      acc.id = parts[10];
    }
    return acc;
  }

  static async loadAll(context: common.Context): Promise<DavAccount[]> {
    const result: DavAccount[] = [];
    let migrated: boolean = false;
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, AccountStore.STORE);
      const count: number = await store.get(AccountStore.COUNT_KEY, 0) as number;
      for (let i = 0; i < count; i++) {
        const raw = await store.get(`acc_${i}`, '') as string;
        if (raw === '') {
          continue;
        }
        const acc = AccountStore.decodeAccount(raw);
        if (acc !== null) {
          if (acc.id === '') {
            // 旧版本存储没有 id：补发一个并标记需要回写，保证 id 跨启动稳定
            acc.id = `acc${Date.now()}_${i}`;
            migrated = true;
          }
          result.push(acc);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`读取账号失败: ${e.message}`);
    }
    if (migrated) {
      try {
        await AccountStore.saveAll(context, result);
        console.info('旧版账号数据已迁移：补充持久化账号 id');
      } catch (err) {
        const e = err as BusinessError;
        console.error(`账号 id 迁移回写失败: ${e.message}`);
      }
    }
    return result;
  }

  static async saveAll(context: common.Context, accounts: DavAccount[]): Promise<void> {
    const store: preferences.Preferences =
      await preferences.getPreferences(context, AccountStore.STORE);
    const oldCount: number = await store.get(AccountStore.COUNT_KEY, 0) as number;
    for (let i = 0; i < oldCount; i++) {
      store.delete(`acc_${i}`);
    }
    for (let i = 0; i < accounts.length; i++) {
      await store.put(`acc_${i}`, AccountStore.encodeAccount(accounts[i]));
    }
    await store.put(AccountStore.COUNT_KEY, accounts.length);
    await store.flush();
  }

  static async addAccount(context: common.Context, acc: DavAccount): Promise<void> {
    const list: DavAccount[] = await AccountStore.loadAll(context);
    list.push(acc);
    await AccountStore.saveAll(context, list);
  }
}