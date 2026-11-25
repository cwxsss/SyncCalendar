// entry/src/main/ets/common/GeoUtil.ets
// 地理编码与坐标转换工具（从 Index.ets 抽离）：正向地理编码 + WGS84 → GCJ02 火星坐标转换
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogUtil } from './LogUtil';

export class GeoUtil {
  /** 正向地理编码：地址 → 坐标（系统服务，无需高德 key、无需定位权限） */
  static async geocodeAddress(address: string): Promise<number[] | null> {
    try {
      if (!geoLocationManager.isGeocoderAvailable()) {
        LogUtil.write('系统地理编码服务不可用');
        return null;
      }
      const req: geoLocationManager.GeoCodeRequest = { description: address, maxItems: 1 };
      const list: geoLocationManager.GeoAddress[] =
        await geoLocationManager.getAddressesFromLocationName(req);
      if (list.length > 0 && list[0].latitude !== undefined && list[0].longitude !== undefined) {
        return [list[0].latitude, list[0].longitude];
      }
      LogUtil.write('地理编码无结果（地点已脱敏）');
    } catch (err) {
      LogUtil.write(`地理编码失败：${(err as BusinessError).message}`);
    }
    return null;
  }

  /** WGS84 → GCJ02 火星坐标转换（中国境内；标准偏移算法） */
  static wgs84ToGcj02(wlat: number, wlon: number): number[] {
    const a: number = 6378245.0;
    const ee: number = 0.00669342162296594323;
    const transformLat = (x: number, y: number): number => {
      let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y
        + 0.2 * Math.sqrt(Math.abs(x));
      ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
      ret += (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
      ret += (160.0 * Math.sin(y / 12.0 * Math.PI) + 320.0 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
      return ret;
    };
    const transformLon = (x: number, y: number): number => {
      let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
      ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
      ret += (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
      ret += (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
      return ret;
    };
    if (wlon < 72.004 || wlon > 137.8347 || wlat < 0.8293 || wlat > 55.8271) {
      return [wlat, wlon];
    }
    let dLat: number = transformLat(wlon - 105.0, wlat - 35.0);
    let dLon: number = transformLon(wlon - 105.0, wlat - 35.0);
    const radLat: number = wlat / 180.0 * Math.PI;
    let magic: number = Math.sin(radLat);
    magic = 1 - ee * magic * magic;
    const sqrtMagic: number = Math.sqrt(magic);
    dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
    dLon = (dLon * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
    return [wlat + dLat, wlon + dLon];
  }
}
