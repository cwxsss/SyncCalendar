// entry/src/main/ets/common/AccountStore.ets
// DAV 账号持久化（加密版）：
// - 账号列表（含密码）序列化为 JSON 后用 AES-256-GCM 整体加密，
//   存储为 caldav_vault 偏好中的 data_b64（iv:密文+tag）；
// - AES 密钥首次随机生成后存于同一偏好（key_b64）；
// - 旧版明文存储（caldav_account 的 acc_0..n）在首次 loadAll 时自动迁移并清除。
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const TYPE_CALDAV: string = 'caldav';
export const TYPE_CARDDAV: string = 'carddav';
export const TYPE_WEBDAV: string = 'webdav';
export const TYPE_KEYS: string[] = [TYPE_CALDAV, TYPE_CARDDAV, TYPE_WEBDAV];

/** 本机事件所属的虚拟日历 key */
export const LOCAL_CAL_KEY: string = 'local';

/** 旧版明文存储（迁移后清除） */
const LEGACY_STORE: string = 'caldav_account';
const LEGACY_COUNT_KEY: string = 'accountCount';

/** 加密存储 */
const VAULT_STORE: string = 'caldav_vault';
const VAULT_KEY: string = 'key_b64';
const VAULT_DATA: string = 'data_b64';

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
  /** 各日历本写权限（'1'=可写 '0'=只读），与 calendarHrefs 一一对应；空数组表示未知（按可写处理） */
  calendarWritable: string[] = [];
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
  writable: boolean = true; // 只读日历本中的日程只能查看详情，不能编辑
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

function bytesToB64(u: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(u);
}

function b64ToBytes(s: string): Uint8Array {
  return new util.Base64Helper().decodeSync(s);
}

function strToBytes(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function bytesToStr(u: Uint8Array): string {
  return new util.TextDecoder('utf-8').decodeToString(u);
}

/** 账号加密存储实现（AES-256-GCM，密钥持久化） */
class Vault {
  private static keyB64: string = ''; // 进程内缓存，避免每轮同步重复读偏好

  static async prefs(context: common.Context): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, VAULT_STORE);
  }

  /** 获取（或首次生成）AES-256 密钥 */
  private static async aesKey(context: common.Context): Promise<cryptoFramework.SymKey> {
    if (Vault.keyB64 === '') {
      const store: preferences.Preferences = await Vault.prefs(context);
      Vault.keyB64 = await store.get(VAULT_KEY, '') as string;
    }
    const gen: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator('AES256');
    if (Vault.keyB64 !== '') {
      return gen.convertKey({ data: b64ToBytes(Vault.keyB64) });
    }
    const key: cryptoFramework.SymKey = await gen.generateSymKey();
    const raw: cryptoFramework.DataBlob = key.getEncoded();
    Vault.keyB64 = bytesToB64(raw.data);
    const store: preferences.Preferences = await Vault.prefs(context);
    await store.put(VAULT_KEY, Vault.keyB64);
    await store.flush();
    return key;
  }

  private static gcmParams(iv: Uint8Array, authTag: Uint8Array): cryptoFramework.GcmParamsSpec {
    return {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: authTag }
    };
  }

  /** 加密：返回 base64(iv) + ':' + base64(密文+authTag) */
  static async encrypt(context: common.Context, plain: string): Promise<string> {
    const key: cryptoFramework.SymKey = await Vault.aesKey(context);
    const iv: Uint8Array =
      cryptoFramework.createRandom().generateRandomSync(12).data;
    const cipher: cryptoFramework.Cipher =
      cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key,
      Vault.gcmParams(iv, new Uint8Array(16)));
    const out: cryptoFramework.DataBlob =
      await cipher.doFinal({ data: strToBytes(plain) });
    return `${bytesToB64(iv)}:${bytesToB64(out.data)}`;
  }

  /** 解密：失败返回 null（调用方按"无账号"或迁移路径处理） */
  static async decrypt(context: common.Context, stored: string): Promise<string | null> {
    const sep: number = stored.indexOf(':');
    if (sep <= 0) {
      return null;
    }
    const iv: Uint8Array = b64ToBytes(stored.substring(0, sep));
    const blob: Uint8Array = b64ToBytes(stored.substring(sep + 1));
    if (blob.length <= 16) {
      return null;
    }
    const tag: Uint8Array = blob.slice(blob.length - 16);
    const ct: Uint8Array = blob.slice(0, blob.length - 16);
    const key: cryptoFramework.SymKey = await Vault.aesKey(context);
    const cipher: cryptoFramework.Cipher =
      cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key,
      Vault.gcmParams(iv, tag));
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: ct });
    return bytesToStr(out.data);
  }
}

/**
 * 账号持久化：加密 JSON 存储 + 旧版明文自动迁移
 */
export class AccountStore {
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
    if (parts.length >= 12) {
      acc.calendarWritable = parts[11] === '' ? [] : parts[11].split(';');
    }
    return acc;
  }

  /** 旧版明文账号编码（迁移旧数据时使用） */
  private static encodeLegacyAccount(acc: DavAccount): string {
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
      safe(acc.id),
      acc.calendarWritable.join(';')
    ];
    return parts.join('|');
  }

  /** 从旧版明文存储读取（无则返回 null） */
  private static async loadLegacy(context: common.Context): Promise<DavAccount[] | null> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, LEGACY_STORE);
      const count: number = await store.get(LEGACY_COUNT_KEY, 0) as number;
      if (count <= 0) {
        return null;
      }
      const result: DavAccount[] = [];
      for (let i = 0; i < count; i++) {
        const raw = await store.get(`acc_${i}`, '') as string;
        if (raw === '') {
          continue;
        }
        const acc = AccountStore.decodeAccount(raw);
        if (acc !== null) {
          if (acc.id === '') {
            acc.id = `acc${Date.now()}_${i}`;
          }
          result.push(acc);
        }
      }
      return result;
    } catch (err) {
      return null;
    }
  }

  /** 清除旧版明文存储（迁移完成后调用） */
  private static async clearLegacy(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, LEGACY_STORE);
      const count: number = await store.get(LEGACY_COUNT_KEY, 0) as number;
      for (let i = 0; i < count; i++) {
        store.delete(`acc_${i}`);
      }
      store.delete(LEGACY_COUNT_KEY);
      await store.flush();
    } catch (err) {
      // 清理失败不影响使用，下次迁移再试
    }
  }

  static async loadAll(context: common.Context): Promise<DavAccount[]> {
    // 1) 新加密存储
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const data: string = await store.get(VAULT_DATA, '') as string;
      if (data !== '') {
        const plain: string | null = await Vault.decrypt(context, data);
        if (plain !== null) {
          const arr: Array<Record<string, Object>> =
            JSON.parse(plain) as Array<Record<string, Object>>;
          const result: DavAccount[] = [];
          for (const o of arr) {
            const a = new DavAccount();
            a.id = o['id'] !== undefined ? o['id'] as string : '';
            a.type = o['type'] !== undefined ? o['type'] as string : TYPE_CALDAV;
            a.name = o['name'] !== undefined ? o['name'] as string : '';
            a.serverUrl = o['serverUrl'] !== undefined ? o['serverUrl'] as string : '';
            a.username = o['username'] !== undefined ? o['username'] as string : '';
            a.password = o['password'] !== undefined ? o['password'] as string : '';
            a.calendarHrefs = o['calendarHrefs'] !== undefined ? o['calendarHrefs'] as string[] : [];
            a.calendarNames = o['calendarNames'] !== undefined ? o['calendarNames'] as string[] : [];
            a.calendarColors = o['calendarColors'] !== undefined ? o['calendarColors'] as string[] : [];
            a.calendarWritable = o['calendarWritable'] !== undefined ? o['calendarWritable'] as string[] : [];
            a.itemCount = o['itemCount'] !== undefined ? o['itemCount'] as number : 0;
            a.lastSyncTime = o['lastSyncTime'] !== undefined ? o['lastSyncTime'] as string : '';
            if (a.id === '') {
              a.id = `acc${Date.now()}_${result.length}`;
            }
            result.push(a);
          }
          console.info(`[AccountStore] loadAll: ${result.length} 个账号（加密存储）`);
          return result;
        }
        console.error('[AccountStore] 加密账号数据解密失败');
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[AccountStore] 读取加密账号失败: ${e.message}`);
    }

    // 2) 旧版明文存储 → 迁移
    const legacy: DavAccount[] | null = await AccountStore.loadLegacy(context);
    if (legacy !== null) {
      console.info(`[AccountStore] 迁移 ${legacy.length} 个明文账号到加密存储`);
      await AccountStore.saveAll(context, legacy, true);
      await AccountStore.clearLegacy(context);
      return legacy;
    }
    return [];
  }

  /**
   * 保存全部账号（整体加密写入）。
   * 防御：当前已有账号时，禁止用空列表覆盖（调用方因读取异常拿到空列表再回写，
   * 会把所有账号抹掉）。仅删除账号的合法场景通过 force=true 放行。
   */
  static async saveAll(context: common.Context, accounts: DavAccount[], force: boolean = false): Promise<void> {
    // 防御：先看加密存储里现有数量（空列表覆盖保护）
    let existing: number = -1;
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const data: string = await store.get(VAULT_DATA, '') as string;
      if (data !== '') {
        const plain: string | null = await Vault.decrypt(context, data);
        if (plain !== null) {
          existing = (JSON.parse(plain) as Array<Record<string, Object>>).length;
        }
      }
    } catch (err) {
      // 读取失败按"未知"处理，不拦截
      existing = -1;
    }
    if (accounts.length === 0 && existing > 0 && !force) {
      console.error(`[AccountStore] 拒绝用空列表覆盖账号存储（原有 ${existing} 个账号）`);
      throw new Error('账号列表为空，已阻止覆盖存储（保护原有账号数据）');
    }
    const plain: string = JSON.stringify(accounts);
    const enc: string = await Vault.encrypt(context, plain);
    const store: preferences.Preferences = await Vault.prefs(context);
    await store.put(VAULT_DATA, enc);
    await store.flush();
    console.info(`[AccountStore] saveAll: ${accounts.length} 个账号已加密写入`);
  }

  static async addAccount(context: common.Context, acc: DavAccount): Promise<void> {
    const list: DavAccount[] = await AccountStore.loadAll(context);
    list.push(acc);
    await AccountStore.saveAll(context, list);
  }
}
