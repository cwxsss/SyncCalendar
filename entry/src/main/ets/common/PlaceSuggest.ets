// entry/src/main/ets/common/PlaceSuggest.ets
// 地点补全/选点：基于鸿蒙系统内置的 Map Kit（Site Kit + sceneMap）
//
// 为什么用华为 Map Kit 而不是高德：
//  1) 系统内置、无需第三方 SDK 依赖，也不需要我们自己维护一个 API Key；
//  2) Site Kit 的 queryAutoComplete / searchByText / reverseGeocode **不需要任何权限**
//     （SDK 声明里没有 @permission），符合本项目「权限只在用户主动点该功能时申请」的硬约束；
//  3) HarmonyOS 5.0 及以上 Map Kit 的地图加载/POI 搜索/地理编码当前免费（官方论坛口径）。
//
// ⚠️ 前置条件（必须由用户在 AGC 完成，代码无法替代）：
//    AGC 项目 → 开放能力管理 → 打开「地图服务」，并**重新申请 Profile**（旧的 Profile 不含地图能力）。
//    未开通时调用会抛 1002600004（The Map permission is not enabled）。
//    因此本类所有入口都必须**优雅降级**：失败只返回空列表，绝不影响日程本身的保存。
import { site, sceneMap, mapCommon } from '@kit.MapKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogUtil } from './LogUtil';

/** 一条地点候选（界面直接消费） */
export class PlaceItem {
  /** Site Kit 的地点 ID，可用于 searchById 取详情 */
  siteId: string = '';
  /** 地点名称，如「星巴克(中关村店)」 */
  name: string = '';
  /** 完整格式化地址，如「北京市海淀区中关村大街1号」 */
  address: string = '';
  /** 纬度（无法取得时为 0） */
  lat: number = 0;
  /** 经度（无法取得时为 0） */
  lng: number = 0;
  /** 是否有有效坐标 */
  hasCoord: boolean = false;

  /** 界面上第一行显示：有名称用名称，否则用地址 */
  get title(): string {
    return this.name !== '' ? this.name : this.address;
  }

  /** 界面上第二行显示：名称+地址重复时不显示 */
  get subtitle(): string {
    if (this.address === '') {
      return '';
    }
    if (this.name === '' || this.address === this.name) {
      return '';
    }
    return this.address;
  }

  /** 写入日程 location 字段的文本：优先完整地址，退化为名称 */
  get locationText(): string {
    return this.address !== '' ? this.address : this.name;
  }
}

export class PlaceSuggest {
  /** 地图能力是否可用（false 时界面应显示提示而不是反复重试） */
  private static unavailable: boolean = false;
  /** 最近一次失败原因（给界面显示，便于用户/开发者判断是"没开通"还是"网络问题"） */
  private static lastError: string = '';
  /** 当前在途请求序号：用于丢弃过期结果（边打字边搜时后发先至） */
  private static seq: number = 0;

  static isUnavailable(): boolean {
    return PlaceSuggest.unavailable;
  }

  static getLastError(): string {
    return PlaceSuggest.lastError;
  }

  /**
   * 关键字补全：输入几个字返回候选地点。
   * 失败/未开通一律返回空数组（不抛异常，不影响其他功能）。
   * @param keyword 用户已输入的关键字
   * @param context 可选，传了就用带 context 的重载（定位更准）
   */
  static async query(keyword: string, context?: common.Context): Promise<PlaceItem[]> {
    const q: string = keyword.trim();
    if (q === '') {
      return [];
    }
    if (PlaceSuggest.unavailable) {
      return [];
    }
    // 序号机制：只接受最后一次请求的结果
    PlaceSuggest.seq++;
    const mySeq: number = PlaceSuggest.seq;
    try {
      const params: site.QueryAutoCompleteParams = {
        query: q,
        language: 'zh-CN',
        isCityLimit: false
      };
      const res: site.QueryAutoCompleteResult = context !== undefined
        ? await site.queryAutoComplete(context, params)
        : await site.queryAutoComplete(params);
      if (mySeq !== PlaceSuggest.seq) {
        // 已有更新的请求发出，丢弃本次结果
        return [];
      }
      return PlaceSuggest.toItems(res.sites);
    } catch (err) {
      PlaceSuggest.handleError('补全', err);
      // 补全失败时退一步用关键字搜索（部分环境 autoComplete 不可用但 searchByText 可用）
      return await PlaceSuggest.searchFallback(q, context, mySeq);
    }
  }

  /**
   * 关键字搜索（补全失败时的兜底，也用于用户直接点"搜索"）。
   */
  static async search(keyword: string, context?: common.Context): Promise<PlaceItem[]> {
    const q: string = keyword.trim();
    if (q === '' || PlaceSuggest.unavailable) {
      return [];
    }
    PlaceSuggest.seq++;
    const mySeq: number = PlaceSuggest.seq;
    return await PlaceSuggest.searchFallback(q, context, mySeq);
  }

  private static async searchFallback(keyword: string, context: common.Context | undefined,
    mySeq: number): Promise<PlaceItem[]> {
    try {
      const params: site.SearchByTextParams = {
        query: keyword,
        language: 'zh-CN'
      };
      const res: site.SearchByTextResult = context !== undefined
        ? await site.searchByText(context, params)
        : await site.searchByText(params);
      if (mySeq !== PlaceSuggest.seq) {
        return [];
      }
      return PlaceSuggest.toItems(res.sites);
    } catch (err) {
      PlaceSuggest.handleError('搜索', err);
      return [];
    }
  }

  /**
   * 打开系统地图选点页，返回用户选中的地点（用户取消返回 null）。
   * 这是最省事也最不容易出错的方式：地图、搜索、周边都由系统界面提供。
   */
  static async pickOnMap(context: common.UIAbilityContext): Promise<PlaceItem | null> {
    try {
      const options: sceneMap.LocationChoosingOptions = {
        language: 'zh-CN',
        searchEnabled: true,
        showNearbyPoi: true
      };
      const r: sceneMap.LocationChoosingResult = await sceneMap.chooseLocation(context, options);
      const item: PlaceItem = new PlaceItem();
      item.siteId = r.siteId !== undefined ? r.siteId : '';
      item.name = r.name !== undefined ? r.name : '';
      item.address = r.address !== undefined ? r.address : '';
      if (r.location !== undefined) {
        item.lat = r.location.latitude;
        item.lng = r.location.longitude;
        item.hasCoord = true;
      }
      // 两者都空视为取消/无效选择
      if (item.name === '' && item.address === '') {
        return null;
      }
      return item;
    } catch (err) {
      PlaceSuggest.handleError('地图选点', err);
      return null;
    }
  }

  /** 生成"名称 — 地址"这种便于粘贴进备注/地点的单行文本 */
  static formatOneLine(item: PlaceItem): string {
    if (item.name !== '' && item.address !== '' && item.name !== item.address) {
      return `${item.name}｜${item.address}`;
    }
    return item.locationText;
  }

  private static toItems(sites: site.Site[] | undefined): PlaceItem[] {
    const out: PlaceItem[] = [];
    if (sites === undefined) {
      return out;
    }
    for (let i = 0; i < sites.length; i++) {
      const s: site.Site = sites[i];
      const item: PlaceItem = new PlaceItem();
      item.siteId = s.siteId !== undefined ? s.siteId : '';
      item.name = s.name !== undefined ? s.name : '';
      // formatAddress 是"省市区+街道门牌"的完整串，最适合写进 LOCATION
      item.address = s.formatAddress !== undefined ? s.formatAddress : '';
      if (item.address === '' && s.addressComponent !== undefined) {
        // 极少数数据只有结构化 addressComponent（字段仅 countryName/locality/city/streetNumber），
        // 按"国 → 城市 → 区县(locality) → 街道门牌"拼一个保底地址
        item.address = PlaceSuggest.joinAddress(s.addressComponent);
      }
      if (s.location !== undefined) {
        item.lat = s.location.latitude;
        item.lng = s.location.longitude;
        item.hasCoord = true;
      }
      if (item.name !== '' || item.address !== '') {
        out.push(item);
      }
    }
    return out;
  }

  /** 从结构化地址组件拼一条保底地址（SDK 里就这几个字段） */
  private static joinAddress(ac: site.AddressComponent): string {
    const parts: string[] = [];
    if (ac.countryName !== undefined && ac.countryName !== '') {
      parts.push(ac.countryName);
    }
    if (ac.city !== undefined && ac.city.cityName !== undefined && ac.city.cityName !== '') {
      parts.push(ac.city.cityName);
    }
    if (ac.locality !== undefined && ac.locality !== '') {
      parts.push(ac.locality);
    }
    if (ac.streetNumber !== undefined) {
      const sn: site.StreetNumber = ac.streetNumber;
      if (sn.streetName !== undefined && sn.streetName !== '') {
        parts.push(sn.streetName);
      }
      if (sn.streetNumber !== undefined && sn.streetNumber !== '') {
        parts.push(sn.streetNumber);
      }
    }
    return parts.join('');
  }

  /**
   * 统一错误处理：
   *  - 1002600004 地图权限未开通 → 标记不可用，界面不再重试（避免每次打字都打一遍网络）
   *  - 1002600003 鉴权失败（Profile 未含地图能力）
   *  - 1002600002 连不上服务器
   */
  private static handleError(op: string, err: Object): void {
    const e = err as BusinessError;
    const code: number = e.code !== undefined ? e.code : 0;
    PlaceSuggest.lastError = `${op}失败(code=${code}): ${e.message}`;
    if (code === 1002600004 || code === 1002600003) {
      PlaceSuggest.unavailable = true;
      LogUtil.write(`[地点] ${op}不可用(code=${code})：需在 AGC 打开「地图服务」并重新申请 Profile`);
    } else {
      LogUtil.write(`[地点] ${PlaceSuggest.lastError}`);
    }
  }
}