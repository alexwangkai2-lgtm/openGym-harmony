import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'openGym';

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'onBackup ok');
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    hilog.info(DOMAIN, TAG, 'onRestore ok %{public}s', JSON.stringify(bundleVersion));
  }
}
