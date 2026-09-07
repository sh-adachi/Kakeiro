class SyncError(Exception):
    def __init__(self, message, status=502, retry_after=0, reauthenticate=False, preserve_pending=False):
        super().__init__(message)
        self.message = message
        self.status = status
        self.retry_after = retry_after
        self.reauthenticate = reauthenticate
        self.preserve_pending = preserve_pending


class Cancelled(Exception):
    pass


INVALID_DATA = "取得データを安全に取り込めませんでした。前回のデータを保持しています。"
REAUTHENTICATE = "Moneytree の再認証が必要です。連携画面から認証してください。"
