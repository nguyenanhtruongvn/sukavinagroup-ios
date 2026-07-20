import React, { useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import ReactDOM from 'react-dom/client';
import './styles.css';

type Dashboard = {
  employeeCode: string;
  name: string;
  role: string;
  remainingLeaveDays: number;
  attendanceStatus: string;
  payrollStatus: string;
  attendanceRecords: Array<{
    id: string;
    punchedAt: string;
    source: string;
    originType?: string | null;
    machineNo: number;
  }>;
  contentItems: Array<{
    id: string;
    page: string;
    key: string;
    title: string;
    body: string;
    sortOrder: number;
    published: boolean;
    createdAt: string;
  }>;
};

type EmployeeRecord = {
  id: string;
  employeeCode?: string;
  fullName?: string;
  jobTitle?: string;
  department?: string;
  managerEmployeeCode?: string;
  hireDate?: string;
  contractType?: string;
  phoneNumber?: string;
  gmailEmail?: string;
  authProvider?: string;
  remainingLeaveDays?: number;
  attendanceStatus?: string;
  payrollStatus?: string;
  active?: boolean;
  gmailVerified?: boolean;
  accountType?: 'SUPER_ADMIN' | 'ADMIN' | 'EMPLOYEE';
  permissions?: string[];
  protected?: boolean;
  savedAccountType?: 'SUPER_ADMIN' | 'ADMIN' | 'EMPLOYEE';
  createdAt?: string;
};

type AttendanceMonth = {
  month: string;
  days: Array<{
    date: string;
    checkIn: string | null;
    checkOut: string | null;
    punchCount: number;
    sources: string[];
    punches: Array<{
      id: string;
      punchedAt: string;
      source: string;
      machineNo: number;
    }>;
  }>;
};

const formatAttendanceTime = (value?: string | null) =>
  value
    ? new Date(value).toLocaleTimeString('vi-VN', {
        hour: '2-digit',
        minute: '2-digit',
      })
    : '--:--';

type PermissionKey =
  | 'content.manage'
  | 'employees.manage'
  | 'accounts.manage';

type AccessProfile = {
  id?: string;
  employeeCode: string;
  name: string;
  role: string;
  accountType: 'SUPER_ADMIN' | 'ADMIN' | 'EMPLOYEE';
  permissions: string[];
  protected?: boolean;
};

const permissionOptions: Array<{ key: PermissionKey; label: string; description: string }> = [
  { key: 'content.manage', label: 'Quản lý bài viết', description: 'Thêm, sửa, xóa và xuất bản nội dung.' },
  { key: 'employees.manage', label: 'Quản lý nhân viên', description: 'Thêm, sửa, xóa hồ sơ nhân viên.' },
  { key: 'accounts.manage', label: 'Phân quyền tài khoản', description: 'Nâng cấp tài khoản và gán quyền admin.' },
];

type ContentItem = Dashboard['contentItems'][number];

type MediaItem = {
  name: string;
  url: string;
  type: 'image' | 'video';
  size: number;
  createdAt: string;
};

type EmployeeRequest = {
  id: string;
  kind: 'leave' | 'late' | 'early' | 'overtime' | 'business';
  startsAt: string;
  endsAt: string;
  reason: string;
  status: 'pending' | 'approved' | 'rejected' | 'cancelled';
  createdAt: string;
  decisionNote?: string | null;
  autoApproved?: boolean;
  employee?: { fullName: string; employeeCode: string };
};

type RequestNotification = {
  id: string;
  type: string;
  title: string;
  message: string;
  requestId?: string | null;
  read: boolean;
  createdAt: string;
};

const requestKindLabels: Record<EmployeeRequest['kind'], string> = {
  leave: 'Nghỉ phép',
  late: 'Đi trễ',
  early: 'Về sớm',
  overtime: 'Làm thêm giờ',
  business: 'Công tác',
};

const requestStatusLabels: Record<EmployeeRequest['status'], string> = {
  pending: 'Chờ duyệt',
  approved: 'Đã duyệt',
  rejected: 'Từ chối',
  cancelled: 'Đã hủy',
};

const requestKindIcons: Record<EmployeeRequest['kind'], string> = {
  leave: '◷', late: '↘', early: '↗', overtime: '☾', business: '✈',
};

class AppErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { hasError: boolean; message: string }
> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { hasError: false, message: '' };
  }

  static getDerivedStateFromError(error: Error) {
    return { hasError: true, message: error.message };
  }

  componentDidCatch(error: Error) {
    // Keep the UI visible so we can debug the exact crash.
    console.error('App crashed', error);
  }

  render() {
    if (this.state.hasError) {
      return (
        <main className="auth-shell">
          <section className="auth-card">
            <p className="panel-label">Lỗi ứng dụng</p>
            <h1>Trang đang bị dừng do lỗi runtime</h1>
            <p className="panel-note">{this.state.message}</p>
          </section>
        </main>
      );
    }

    return this.props.children;
  }
}

const notificationStorageKey = (employeeCode: string) =>
  `sukavina_employee_news_seen_${employeeCode.toLowerCase()}`;

function safeDateValue(value?: string) {
  const time = value ? new Date(value).getTime() : 0;
  return Number.isFinite(time) ? time : 0;
}

function stripHtml(input: string) {
  return input
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<\/?[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/\s+/g, ' ')
    .trim();
}

function summarizeText(input: string, maxLength = 120) {
  const clean = stripHtml(input);
  if (clean.length <= maxLength) return clean;
  return `${clean.slice(0, maxLength).trimEnd()}...`;
}

function sanitizeArticleHtml(input: string) {
  const documentNode = new DOMParser().parseFromString(input, 'text/html');
  documentNode
    .querySelectorAll('script, style, iframe, object, embed, form, input, button')
    .forEach((element) => element.remove());

  documentNode.querySelectorAll('*').forEach((element) => {
    [...element.attributes].forEach((attribute) => {
      const name = attribute.name.toLowerCase();
      const value = attribute.value.trim().toLowerCase();
      if (name.startsWith('on') || value.startsWith('javascript:')) {
        element.removeAttribute(attribute.name);
      }
    });
  });

  return documentNode.body.innerHTML;
}

function PublicFooter() {
  return (
    <footer className="public-footer">
      <a href="/privacy-policy">Chính sách quyền riêng tư</a>
      <a href="/support">Hỗ trợ</a>
      <span>© 2026 Sukavina Group</span>
    </footer>
  );
}

function LegalPage({ page }: { page: 'privacy' | 'support' }) {
  const isPrivacy = page === 'privacy';
  return (
    <main className="legal-shell">
      <header className="legal-header">
        <a className="legal-brand" href="/">SUKAVINA PORTAL</a>
        <a className="ghost-button legal-back" href="/">Về trang đăng nhập</a>
      </header>
      <article className="legal-card">
        <p className="panel-label">{isPrivacy ? 'Quyền riêng tư' : 'Trung tâm hỗ trợ'}</p>
        <h1>{isPrivacy ? 'Chính sách quyền riêng tư' : 'Hỗ trợ người dùng'}</h1>
        <p className="legal-updated">Cập nhật lần cuối: 16/07/2026</p>
        {isPrivacy ? (
          <>
            <section>
              <h2>1. Phạm vi áp dụng</h2>
              <p>Chính sách này áp dụng cho website và ứng dụng Sukavina Portal, được sử dụng để quản lý tài khoản nhân viên, thông báo nội bộ và thông tin công việc.</p>
            </section>
            <section>
              <h2>2. Dữ liệu chúng tôi thu thập</h2>
              <div className="privacy-data-grid">
                <div><strong>Họ và tên</strong><span>Nhận diện và hiển thị hồ sơ nhân viên.</span></div>
                <div><strong>Địa chỉ Gmail</strong><span>Xác minh tài khoản và gửi thông báo liên quan.</span></div>
                <div><strong>Số điện thoại</strong><span>Liên hệ và hỗ trợ đăng nhập khi được cung cấp.</span></div>
                <div><strong>Mã nhân viên</strong><span>Định danh tài khoản trong hệ thống Sukavina.</span></div>
                <div><strong>Dữ liệu sử dụng</strong><span>Nhật ký truy cập, thao tác và lỗi kỹ thuật phục vụ bảo mật, vận hành.</span></div>
              </div>
            </section>
            <section>
              <h2>3. Cách sử dụng và chia sẻ dữ liệu</h2>
              <p>Dữ liệu chỉ được dùng để cung cấp dịch vụ, xác minh danh tính, vận hành nội bộ, hỗ trợ người dùng và bảo vệ hệ thống. Sukavina không bán dữ liệu cá nhân. Dữ liệu chỉ được chia sẻ với nhà cung cấp hạ tầng cần thiết hoặc cơ quan có thẩm quyền khi pháp luật yêu cầu.</p>
            </section>
            <section>
              <h2>4. Lưu trữ và bảo mật</h2>
              <p>Dữ liệu được lưu trên máy chủ có kiểm soát truy cập, HTTPS, tường lửa và cơ chế giám sát đăng nhập. Dữ liệu được giữ trong thời gian tài khoản hoạt động hoặc lâu hơn khi có nghĩa vụ pháp lý hợp lệ.</p>
            </section>
            <section>
              <h2>5. Quyền của người dùng</h2>
              <p>Bạn có thể yêu cầu truy cập, sửa hoặc xóa dữ liệu. Người dùng có thể khởi tạo xóa toàn bộ tài khoản trong khu vực tài khoản sau khi đăng nhập. Một số dữ liệu có thể được giữ lại nếu pháp luật yêu cầu.</p>
            </section>
            <section>
              <h2>6. Liên hệ</h2>
              <p>Mọi câu hỏi về quyền riêng tư gửi tới <a href="mailto:sukavina01@gmail.com">sukavina01@gmail.com</a>.</p>
            </section>
          </>
        ) : (
          <>
            <section>
              <h2>Liên hệ hỗ trợ</h2>
              <p>Nếu gặp lỗi đăng nhập, xác minh Gmail, thông báo hoặc dữ liệu tài khoản, hãy liên hệ đội ngũ Sukavina.</p>
              <div className="support-contact">
                <span>Email hỗ trợ</span>
                <a href="mailto:sukavina01@gmail.com">sukavina01@gmail.com</a>
              </div>
            </section>
            <section>
              <h2>Thông tin nên cung cấp</h2>
              <p>Vui lòng gửi mã nhân viên, mô tả sự cố, thời điểm xảy ra và ảnh chụp màn hình nếu có. Không gửi mật khẩu hoặc mã xác minh Gmail.</p>
            </section>
            <section>
              <h2>Quản lý và xóa tài khoản</h2>
              <p>Sau khi đăng nhập, mở phần “Quyền riêng tư và tài khoản” rồi chọn “Xóa tài khoản”. Bạn cần nhập lại mật khẩu và xác nhận trước khi dữ liệu được xóa vĩnh viễn.</p>
            </section>
          </>
        )}
      </article>
      <PublicFooter />
    </main>
  );
}

function App() {
  const isAdminRoute = window.location.pathname.startsWith('/admin');
  const isPrivacyRoute = window.location.pathname === '/privacy-policy';
  const isSupportRoute = window.location.pathname === '/support';
  const [loginId, setLoginId] = useState('');
  const [password, setPassword] = useState('');
  const registerMode = false;
  const verificationMode = false;
  const verificationCode = '';
  const registerForm = {
    employeeCode: '',
    fullName: '',
    phoneNumber: '',
    gmailEmail: '',
    password: '',
  };
  const [token, setToken] = useState<string | null>(
    localStorage.getItem('sukavina_token'),
  );
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const [contents, setContents] = useState<Dashboard['contentItems']>([]);
  const [sharedContent, setSharedContent] = useState<Dashboard['contentItems']>(
    [],
  );
  const [employees, setEmployees] = useState<EmployeeRecord[]>([]);
  const [accounts, setAccounts] = useState<EmployeeRecord[]>([]);
  const [currentUser, setCurrentUser] = useState<AccessProfile | null>(null);
  const [employeeQuery, setEmployeeQuery] = useState('');
  const [employeeDepartmentFilter, setEmployeeDepartmentFilter] = useState('all');
  const [employeeStatusFilter, setEmployeeStatusFilter] = useState('all');
  const [employeePage, setEmployeePage] = useState(1);
  const [selectedEmployees, setSelectedEmployees] = useState<string[]>([]);
  const [contentPage, setContentPage] = useState(1);
  const [mediaUploading, setMediaUploading] = useState(false);
  const [deleteAccountOpen, setDeleteAccountOpen] = useState(false);
  const [deleteAccountForm, setDeleteAccountForm] = useState({ password: '', confirmation: '' });
  const [adminTab, setAdminTab] = useState<'content' | 'employees' | 'accounts'>(
    'content',
  );
  const [employeeForm, setEmployeeForm] = useState({
    employeeCode: '',
    fullName: '',
    jobTitle: '',
    department: '',
    managerEmployeeCode: '',
    hireDate: '',
    contractType: '',
    phoneNumber: '',
    gmailEmail: '',
    password: '',
    authProvider: 'phone_password',
    remainingLeaveDays: 0,
    attendanceStatus: '',
    payrollStatus: '',
    active: true,
  });
  const [editingEmployeeId, setEditingEmployeeId] = useState<string | null>(
    null,
  );
  const [adminForm, setAdminForm] = useState({
    page: 'employee',
    key: '',
    title: '',
    body: '',
    sortOrder: 0,
    published: true,
  });
  const [editingId, setEditingId] = useState<string | null>(null);
  const [contentComposerOpen, setContentComposerOpen] = useState(false);
  const [autoSortOrder, setAutoSortOrder] = useState(true);
  const [editorMode, setEditorMode] = useState<'visual' | 'source'>('visual');
  const [sourceCode, setSourceCode] = useState('');
  const editorRef = React.useRef<HTMLDivElement | null>(null);
  const imageInputRef = React.useRef<HTMLInputElement | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [toast, setToast] = useState<{
    type: 'success' | 'error';
    message: string;
  } | null>(null);
  const [notificationOpen, setNotificationOpen] = useState(false);
  const [selectedArticle, setSelectedArticle] = useState<ContentItem | null>(null);
  const [attendanceOpen, setAttendanceOpen] = useState(false);
  const [attendanceMonth, setAttendanceMonth] = useState(
    new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit' }).format(new Date()),
  );
  const [adminAccountPickerOpen, setAdminAccountPickerOpen] = useState(false);
  const [adminAccountQuery, setAdminAccountQuery] = useState('');
  const [attendanceHistory, setAttendanceHistory] = useState<AttendanceMonth | null>(null);
  const [attendanceLoading, setAttendanceLoading] = useState(false);
  const [requests, setRequests] = useState<EmployeeRequest[]>([]);
  const [approvalRequests, setApprovalRequests] = useState<EmployeeRequest[]>([]);
  const [requestNotifications, setRequestNotifications] = useState<RequestNotification[]>([]);
  const [notificationRequest, setNotificationRequest] = useState<EmployeeRequest | null>(null);
  const [notificationDecision, setNotificationDecision] = useState<'approved' | 'rejected'>('approved');
  const [notificationDecisionNote, setNotificationDecisionNote] = useState('');
  const [notificationWorking, setNotificationWorking] = useState(false);
  const [requestFilter, setRequestFilter] = useState<'all' | EmployeeRequest['status']>('all');
  const [requestComposerOpen, setRequestComposerOpen] = useState(false);
  const [requestSubmitting, setRequestSubmitting] = useState(false);
  const [requestForm, setRequestForm] = useState({
    kind: 'leave' as EmployeeRequest['kind'],
    startsAt: '',
    endsAt: '',
    reason: '',
  });
  const pageSize = 3;

  const isLoggedIn = Boolean(token);
  const isSuperAdmin =
    currentUser?.accountType === 'SUPER_ADMIN' || currentUser?.employeeCode === 'admin';
  const canAccess = (permission: PermissionKey) =>
    isSuperAdmin || currentUser?.permissions?.includes(permission) === true;

  useEffect(() => {
    if (!token) {
      setCurrentUser(null);
      return;
    }

    const loadAccessProfile = async () => {
      try {
        const response = await fetch('/api/auth/me', {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (!response.ok) throw new Error('Phiên đăng nhập không còn hợp lệ');
        const profile = (await response.json()) as AccessProfile;
        if (isAdminRoute && profile.accountType === 'EMPLOYEE') {
          localStorage.removeItem('sukavina_token');
          setToken(null);
          setError('Tài khoản nhân viên không có quyền truy cập trang quản trị.');
          return;
        }
        setCurrentUser(profile);
      } catch (profileError) {
        localStorage.removeItem('sukavina_token');
        setToken(null);
        setCurrentUser(null);
        setError(profileError instanceof Error ? profileError.message : 'Không kiểm tra được quyền tài khoản');
      }
    };

    void loadAccessProfile();
  }, [token, isAdminRoute]);

  useEffect(() => {
    if (!attendanceOpen || !token) return;
    let active = true;
    setAttendanceLoading(true);
    fetch(`/api/me/attendance?month=${encodeURIComponent(attendanceMonth)}`, {
      headers: { Authorization: `Bearer ${token}` },
      cache: 'no-store',
    })
      .then(async (response) => {
        if (!response.ok) throw new Error('Không tải được lịch sử chấm công');
        return response.json() as Promise<AttendanceMonth>;
      })
      .then((history) => {
        if (active) setAttendanceHistory(history);
      })
      .catch((historyError) => {
        if (active) setError(historyError instanceof Error ? historyError.message : 'Không tải được lịch sử');
      })
      .finally(() => {
        if (active) setAttendanceLoading(false);
      });
    return () => {
      active = false;
    };
  }, [attendanceOpen, attendanceMonth, token]);

  const refreshRequests = async () => {
    if (!token || isAdminRoute) return;
    const options = { headers: { Authorization: `Bearer ${token}` }, cache: 'no-store' as RequestCache };
    const [mineResponse, approvalsResponse, notificationsResponse] = await Promise.all([
      fetch('/api/me/requests', options),
      fetch('/api/me/requests/approvals', options),
      fetch('/api/me/requests/notifications', options),
    ]);
    if (!mineResponse.ok || !approvalsResponse.ok || !notificationsResponse.ok) throw new Error('Không tải được dữ liệu đơn từ');
    setRequests((await mineResponse.json()) as EmployeeRequest[]);
    setApprovalRequests((await approvalsResponse.json()) as EmployeeRequest[]);
    setRequestNotifications((await notificationsResponse.json()) as RequestNotification[]);
  };

  useEffect(() => {
    if (!token || isAdminRoute) {
      setRequests([]);
      setApprovalRequests([]);
      setRequestNotifications([]);
      return;
    }
    void refreshRequests().catch((requestError) => {
      setError(requestError instanceof Error ? requestError.message : 'Không tải được đơn từ');
    });
  }, [token, isAdminRoute]);

  const openRequestComposer = () => {
    const now = new Date();
    const later = new Date(now.getTime() + 8 * 60 * 60 * 1000);
    const localValue = (date: Date) => {
      const offset = date.getTimezoneOffset() * 60_000;
      return new Date(date.getTime() - offset).toISOString().slice(0, 16);
    };
    setRequestForm({ kind: 'leave', startsAt: localValue(now), endsAt: localValue(later), reason: '' });
    setRequestComposerOpen(true);
  };

  const submitRequest = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!token || requestForm.reason.trim().length < 10) return;
    setRequestSubmitting(true);
    try {
      const response = await fetch('/api/me/requests', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...requestForm,
          startsAt: new Date(requestForm.startsAt).toISOString(),
          endsAt: new Date(requestForm.endsAt).toISOString(),
          reason: requestForm.reason.trim(),
        }),
      });
      const result = await response.json().catch(() => null) as { message?: string } | null;
      if (!response.ok) throw new Error(result?.message || 'Không gửi được đơn');
      await refreshRequests();
      setRequestComposerOpen(false);
      setToast({ type: 'success', message: 'Đã gửi đơn thành công.' });
    } catch (requestError) {
      setToast({ type: 'error', message: requestError instanceof Error ? requestError.message : 'Không gửi được đơn' });
    } finally {
      setRequestSubmitting(false);
    }
  };

  const cancelRequest = async (id: string) => {
    if (!token) return;
    const response = await fetch(`/api/me/requests/${encodeURIComponent(id)}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` },
    });
    const result = await response.json().catch(() => null) as { message?: string } | null;
    if (!response.ok) {
      setToast({ type: 'error', message: result?.message || 'Không hủy được đơn' });
      return;
    }
    await refreshRequests();
    setToast({ type: 'success', message: 'Đã hủy đơn.' });
  };

  const fallback = useMemo(
    () => ({
      name: isAdminRoute ? 'Quản trị hệ thống' : 'Nguyễn Văn A',
      role: isAdminRoute ? 'Quản trị viên' : 'Nhân sự vận hành',
      remainingLeaveDays: isAdminRoute ? 0 : 8,
      attendanceStatus: isAdminRoute
        ? 'Khu quản trị không hiển thị bảng công nhân viên'
        : 'Bảng công tháng 7 đã được cập nhật',
      payrollStatus: isAdminRoute
        ? 'Khu quản trị không hiển thị bảng lương nhân viên'
        : 'Bảng lương tháng 7 đang chờ duyệt',
    }),
    [isAdminRoute],
  );

  useEffect(() => {
    const loadSharedContent = async () => {
      try {
        const response = await fetch(`/api/public/news?ts=${Date.now()}`, {
          cache: 'no-store',
        });
        if (!response.ok) return;
        const data = (await response.json()) as Dashboard['contentItems'];
        setSharedContent(data ?? []);
      } catch {
        setSharedContent([]);
      }
    };

    void loadSharedContent();

    const loadDashboard = async () => {
      if (!token) {
        setDashboard(null);
        return;
      }

      setLoading(true);
      setError('');
      try {
        const response = await fetch('/api/me/dashboard', {
          headers: {
            Authorization: `Bearer ${token}`,
          },
        });

        if (!response.ok) {
          throw new Error('Không tải được dữ liệu dashboard');
        }

        const data = (await response.json()) as Dashboard;
        setDashboard(data);
        setContents(data.contentItems ?? []);
        setContentPage(1);
        setAdminForm((current) =>
          current.sortOrder === 0 || current.sortOrder === nextContentSortOrder
            ? { ...current, sortOrder: nextContentSortOrder }
            : current,
        );
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Có lỗi xảy ra');
      } finally {
        setLoading(false);
      }
    };

    void loadDashboard();
  }, [token]);

  useEffect(() => {
    if (!token || isAdminRoute) return;
    let active = true;
    let reconnectTimer = 0;
    const controller = new AbortController();

    const refreshRealtimeDashboard = async () => {
      const response = await fetch('/api/me/dashboard', {
        headers: { Authorization: `Bearer ${token}` },
        cache: 'no-store',
      });
      if (!response.ok || !active) return;
      const fresh = (await response.json()) as Dashboard;
      if (active) setDashboard(fresh);
    };

    const connect = async () => {
      try {
        const response = await fetch('/api/public/news/events', {
          headers: { Accept: 'text/event-stream' },
          signal: controller.signal,
          cache: 'no-store',
        });
        if (!response.ok || !response.body) throw new Error('Realtime unavailable');
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (active) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const events = buffer.split('\n\n');
          buffer = events.pop() ?? '';
          for (const event of events) {
            const dataLine = event.split('\n').find((line) => line.startsWith('data:'));
            if (!dataLine) continue;
            const payload = JSON.parse(dataLine.slice(5).trim()) as { type?: string };
            if (payload.type === 'attendance_changed') void refreshRealtimeDashboard();
            if (payload.type === 'request_changed') void refreshRequests();
          }
        }
      } catch {
        // A dropped stream reconnects without changing the current dashboard.
      }
      if (active) reconnectTimer = window.setTimeout(() => void connect(), 2000);
    };

    void connect();
    return () => {
      active = false;
      controller.abort();
      window.clearTimeout(reconnectTimer);
    };
  }, [token, isAdminRoute]);

  const signIn = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setLoading(true);
    setError('');

    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ loginId, password }),
      });

      if (!response.ok) {
        const result = (await response.json().catch(() => null)) as { message?: string } | null;
        throw new Error(result?.message || 'Sai tài khoản hoặc mật khẩu');
      }

      const data = (await response.json()) as {
        accessToken: string;
        user: AccessProfile;
      };

      if (isAdminRoute && data.user.accountType === 'EMPLOYEE') {
        throw new Error('Tài khoản nhân viên không có quyền truy cập trang quản trị');
      }

      localStorage.setItem('sukavina_token', data.accessToken);
      setCurrentUser(data.user);
      setToken(data.accessToken);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Đăng nhập thất bại');
    } finally {
      setLoading(false);
    }
  };

  const signOut = () => {
    localStorage.removeItem('sukavina_token');
    setToken(null);
    setDashboard(null);
    setCurrentUser(null);
    setAccounts([]);
    setContents([]);
    setNotificationOpen(false);
    setError('');
  };

  const deleteMyAccount = async () => {
    if (!token) return;
    setLoading(true);
    setError('');
    try {
      const response = await fetch('/api/auth/me', {
        method: 'DELETE',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(deleteAccountForm),
      });
      const result = (await response.json().catch(() => null)) as { message?: string } | null;
      if (!response.ok) throw new Error(result?.message || 'Không thể xóa tài khoản');
      signOut();
      setDeleteAccountOpen(false);
      setDeleteAccountForm({ password: '', confirmation: '' });
      setToast({ type: 'success', message: result?.message || 'Tài khoản đã được xóa.' });
    } catch (deleteError) {
      setError(deleteError instanceof Error ? deleteError.message : 'Không thể xóa tài khoản');
    } finally {
      setLoading(false);
    }
  };

  const refreshContent = async () => {
    const response = await fetch('/api/admin/content', {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });
    if (!response.ok) {
      throw new Error('Không tải được nội dung');
    }
    const data = (await response.json()) as Dashboard['contentItems'];
    setContents(data ?? []);
    setContentPage(1);
  };

  const uploadMedia = async (file: File) => {
    if (!token) throw new Error('Phiên đăng nhập đã hết hạn');
    const formData = new FormData();
    formData.append('file', file);
    const response = await fetch('/api/admin/media', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: formData,
    });
    const result = (await response.json().catch(() => null)) as MediaItem | { message?: string } | null;
    if (!response.ok) throw new Error((result as { message?: string })?.message || 'Không tải media lên được');
    return result as MediaItem;
  };

  const refreshSharedContent = async () => {
    try {
      const response = await fetch(`/api/public/news?ts=${Date.now()}`, {
        cache: 'no-store',
      });
      if (!response.ok) return;
      setSharedContent((await response.json()) as Dashboard['contentItems']);
    } catch {
      // Keep current content if the refresh fails.
    }
  };

  const refreshEmployees = async () => {
    if (!token) return;
    const response = await fetch('/api/admin/employees', {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!response.ok) throw new Error('Không tải được danh sách nhân viên');
    setEmployees((await response.json()) as EmployeeRecord[]);
  };

  const registrationDisabled = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
  };

  const refreshAccounts = async () => {
    if (!token) return;
    const response = await fetch('/api/admin/accounts', {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!response.ok) throw new Error('Không tải được danh sách phân quyền');
    const data = (await response.json()) as EmployeeRecord[];
    setAccounts(
      data.map((account) => ({
        ...account,
        savedAccountType: account.accountType,
      })),
    );
  };

  const updateAccountDraft = (
    id: string,
    changes: Partial<Pick<EmployeeRecord, 'accountType' | 'permissions' | 'active'>>,
  ) => {
    setAccounts((current) =>
      current.map((account) =>
        account.id === id ? { ...account, ...changes } : account,
      ),
    );
  };

  const saveAccountAccess = async (account: EmployeeRecord, approve = false) => {
    if (!token || account.protected) return;
    setLoading(true);
    setError('');
    try {
      const response = await fetch(`/api/admin/accounts/${account.id}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          accountType: account.accountType === 'ADMIN' ? 'ADMIN' : 'EMPLOYEE',
          permissions: account.accountType === 'ADMIN' ? account.permissions ?? [] : [],
          active: approve ? true : account.active,
        }),
      });
      if (!response.ok) throw new Error('Không cập nhật được quyền tài khoản');
      await refreshAccounts();
      if (canAccess('employees.manage')) await refreshEmployees();
      setToast({
        type: 'success',
        message: approve
          ? `Đã duyệt tài khoản ${account.fullName || account.employeeCode}.`
          : `Đã lưu phân quyền cho ${account.fullName || account.employeeCode}.`,
      });
    } catch (accessError) {
      const message =
        accessError instanceof Error ? accessError.message : 'Không cập nhật được quyền';
      setError(message);
      setToast({ type: 'error', message });
    } finally {
      setLoading(false);
    }
  };

  const promoteAccountToAdmin = async (account: EmployeeRecord) => {
    await saveAccountAccess({ ...account, accountType: 'ADMIN', permissions: [] });
    setAdminAccountPickerOpen(false);
    setAdminAccountQuery('');
  };

  useEffect(() => {
    if (!toast) return;
    const timeout = window.setTimeout(() => setToast(null), 3500);
    return () => window.clearTimeout(timeout);
  }, [toast]);

  const saveContent = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!token) return;
    setLoading(true);
    setError('');
    const rawBody =
      editorMode === 'source'
        ? sourceCode
        : editorRef.current?.innerHTML ?? adminForm.body;
    const body = sanitizeArticleHtml(rawBody);
    if (body !== adminForm.body) {
      setAdminForm((current) => ({
        ...current,
        body,
      }));
    }
    const resolvedSortOrder =
      editingId || !autoSortOrder ? adminForm.sortOrder : nextContentSortOrder;

    try {
      const response = await fetch(
        editingId ? `/api/admin/content/${editingId}` : '/api/admin/content',
        {
          method: editingId ? 'PATCH' : 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            ...adminForm,
            body,
            sortOrder: resolvedSortOrder,
          }),
        },
      );

      if (!response.ok) {
        throw new Error('Không lưu được dữ liệu');
      }

      setAdminForm({
        page: 'employee',
        key: '',
        title: '',
        body: '',
        sortOrder: editingId ? nextContentSortOrder : resolvedSortOrder + 1,
        published: true,
      });
      setEditingId(null);
      setAutoSortOrder(true);
      setEditorMode('visual');
      setSourceCode('');
      if (editorRef.current) {
        editorRef.current.innerHTML = '';
      }
      await refreshContent();
      await refreshSharedContent();
      setContentComposerOpen(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Không lưu được dữ liệu');
    } finally {
      setLoading(false);
    }
  };

  const editContent = (item: ContentItem) => {
    setContentComposerOpen(true);
    setEditingId(item.id);
    setEditorMode('visual');
    setSourceCode(item.body);
    setAdminForm({
      page: item.page,
      key: item.key,
      title: item.title,
      body: item.body,
      sortOrder: item.sortOrder,
      published: item.published,
    });
    requestAnimationFrame(() => {
      if (editorRef.current) {
        editorRef.current.innerHTML = item.body;
      }
    });
  };

  const openContentComposer = () => {
    setEditingId(null);
    setAdminForm({
      page: 'employee',
      key: '',
      title: '',
      body: '',
      sortOrder: nextContentSortOrder,
      published: true,
    });
    setAutoSortOrder(true);
    setEditorMode('visual');
    setSourceCode('');
    setContentComposerOpen(true);
    requestAnimationFrame(() => {
      if (editorRef.current) editorRef.current.innerHTML = '';
    });
  };

  const closeContentComposer = () => {
    if (loading) return;
    setContentComposerOpen(false);
    setEditingId(null);
    setEditorMode('visual');
    setSourceCode('');
  };

  useEffect(() => {
    if (!contentComposerOpen) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !loading) closeContentComposer();
    };
    document.addEventListener('keydown', closeOnEscape);
    document.body.classList.add('article-modal-open');
    return () => {
      document.removeEventListener('keydown', closeOnEscape);
      document.body.classList.remove('article-modal-open');
    };
  }, [contentComposerOpen, loading]);

  const deleteContent = async (id: string) => {
    if (!token) return;
    setLoading(true);
    setError('');
    try {
      const response = await fetch(`/api/admin/content/${id}`, {
        method: 'DELETE',
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
      if (!response.ok) {
        throw new Error('Không xóa được dữ liệu');
      }
      await refreshContent();
      await refreshSharedContent();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Không xóa được dữ liệu');
    } finally {
      setLoading(false);
    }
  };

  const saveEmployee = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!token) return;
    setLoading(true);
    setError('');

    try {
      const response = await fetch(
        editingEmployeeId
          ? `/api/admin/employees/${editingEmployeeId}`
          : '/api/admin/employees',
        {
          method: editingEmployeeId ? 'PATCH' : 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            ...employeeForm,
            phoneNumber: employeeForm.phoneNumber || null,
            gmailEmail: employeeForm.gmailEmail || null,
            password: employeeForm.password || null,
          }),
        },
      );

      if (!response.ok) {
        const payload = (await response.json().catch(() => null)) as
          | { message?: string | string[] }
          | null;
        const message = Array.isArray(payload?.message)
          ? payload.message.join(', ')
          : payload?.message;
        throw new Error(message || 'Không lưu được nhân viên');
      }

      setEmployeeForm({
        employeeCode: '',
        fullName: '',
        jobTitle: '',
        department: '',
        managerEmployeeCode: '',
        hireDate: '',
        contractType: '',
        phoneNumber: '',
        gmailEmail: '',
        password: '',
        authProvider: 'phone_password',
        remainingLeaveDays: 0,
        attendanceStatus: '',
        payrollStatus: '',
        active: true,
      });
      setEditingEmployeeId(null);
      await refreshEmployees();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Không lưu được nhân viên');
    } finally {
      setLoading(false);
    }
  };

  const editEmployee = (employee: EmployeeRecord) => {
    setEditingEmployeeId(employee.id);
    setEmployeeForm({
      employeeCode: employee.employeeCode ?? '',
      fullName: employee.fullName ?? '',
      jobTitle: employee.jobTitle ?? '',
      department: employee.department ?? '',
      managerEmployeeCode: employee.managerEmployeeCode ?? '',
      hireDate: employee.hireDate?.slice(0, 10) ?? '',
      contractType: employee.contractType ?? '',
      phoneNumber: employee.phoneNumber ?? '',
      gmailEmail: employee.gmailEmail ?? '',
      password: '',
      authProvider: employee.authProvider ?? 'phone_password',
      remainingLeaveDays: employee.remainingLeaveDays ?? 0,
      attendanceStatus: employee.attendanceStatus ?? '',
      payrollStatus: employee.payrollStatus ?? '',
      active: Boolean(employee.active),
    });
    window.setTimeout(() => {
      document.getElementById('employee-form-card')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }, 0);
  };

  const deleteEmployee = async (id: string) => {
    if (!token) return;
    setLoading(true);
    setError('');
    try {
      const response = await fetch(`/api/admin/employees/${id}`, {
        method: 'DELETE',
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!response.ok) {
        throw new Error('Không xóa được nhân viên');
      }
      await refreshEmployees();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Không xóa được nhân viên');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!isAdminRoute || !currentUser) return;
    const availableTabs: Array<'content' | 'employees' | 'accounts'> = [];
    if (canAccess('content.manage')) availableTabs.push('content');
    if (canAccess('employees.manage')) availableTabs.push('employees');
    if (canAccess('accounts.manage')) availableTabs.push('accounts');
    if (availableTabs.length && !availableTabs.includes(adminTab)) {
      setAdminTab(availableTabs[0]);
    }
  }, [isAdminRoute, currentUser, adminTab]);

  useEffect(() => {
    if (!token || !currentUser) return;
    const loadTab = async () => {
      try {
        if (adminTab === 'employees' && canAccess('employees.manage')) await refreshEmployees();
        if (adminTab === 'accounts' && canAccess('accounts.manage')) await refreshAccounts();
        if (adminTab === 'content' && canAccess('content.manage')) await refreshContent();
      } catch (tabError) {
        setError(tabError instanceof Error ? tabError.message : 'Không tải được dữ liệu quản trị');
      }
    };
    void loadTab();
  }, [adminTab, token, currentUser]);

  useEffect(() => {
    if (!token || !currentUser || !isAdminRoute || !canAccess('accounts.manage')) return;

    let active = true;
    let reconnectTimer = 0;
    const controller = new AbortController();
    const loadPendingAccounts = () => {
      void refreshAccounts().catch(() => {
        // The permission-protected endpoint remains the source of truth.
      });
    };
    const connect = async () => {
      try {
        const response = await fetch('/api/admin/accounts/events', {
          headers: { Authorization: `Bearer ${token}` },
          signal: controller.signal,
        });
        if (!response.ok || !response.body) throw new Error('Realtime unavailable');

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (active) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const events = buffer.split('\n\n');
          buffer = events.pop() ?? '';
          for (const event of events) {
            const dataLine = event.split('\n').find((line) => line.startsWith('data:'));
            if (!dataLine) continue;
            const payload = JSON.parse(dataLine.slice(5).trim()) as { type?: string };
            if (payload.type === 'registration_changed') loadPendingAccounts();
          }
        }
      } catch {
        // Reconnect only after a dropped stream; this is not data polling.
      }
      if (active) reconnectTimer = window.setTimeout(() => void connect(), 2000);
    };
    const handleVisibility = () => {
      if (document.visibilityState === 'visible') loadPendingAccounts();
    };

    loadPendingAccounts();
    void connect();
    window.addEventListener('focus', loadPendingAccounts);
    document.addEventListener('visibilitychange', handleVisibility);
    return () => {
      active = false;
      controller.abort();
      window.clearTimeout(reconnectTimer);
      window.removeEventListener('focus', loadPendingAccounts);
      document.removeEventListener('visibilitychange', handleVisibility);
    };
  }, [token, currentUser, isAdminRoute]);

  const nextContentSortOrder = useMemo(() => {
    const maxSort = contents
      .filter((item) => item.page === adminForm.page)
      .reduce(
        (currentMax, item) => Math.max(currentMax, Number(item.sortOrder) || 0),
        0,
      );
    return maxSort > 0 ? maxSort + 1 : 1;
  }, [adminForm.page, contents]);

  useEffect(() => {
    if (adminTab !== 'content' || editingId || !autoSortOrder) return;
    setAdminForm((current) =>
      current.sortOrder === nextContentSortOrder
        ? current
        : {
            ...current,
            sortOrder: nextContentSortOrder,
          },
    );
  }, [adminTab, editingId, autoSortOrder, nextContentSortOrder]);

  useEffect(() => {
    let active = true;
    const loadSharedContent = async () => {
      try {
        const response = await fetch('/api/public/news');
        if (!response.ok) return;
        const data = (await response.json()) as Dashboard['contentItems'];
        if (active) {
          setSharedContent(data ?? []);
        }
      } catch {
        if (active) {
          setSharedContent([]);
        }
      }
    };

    void loadSharedContent();
    const interval = window.setInterval(loadSharedContent, 5000);
    const handleFocus = () => {
      void loadSharedContent();
    };
    window.addEventListener('focus', handleFocus);
    document.addEventListener('visibilitychange', handleFocus);
    return () => {
      active = false;
      window.clearInterval(interval);
      window.removeEventListener('focus', handleFocus);
      document.removeEventListener('visibilitychange', handleFocus);
    };
  }, []);

  const employeeDepartments = useMemo(
    () =>
      [...new Set(employees.map((employee) => employee.department?.trim()).filter(Boolean))]
        .sort((a, b) => String(a).localeCompare(String(b), 'vi')) as string[],
    [employees],
  );

  const filteredEmployees = useMemo(() => {
    const query = employeeQuery.trim().toLowerCase();
    return employees.filter((employee) => {
      const matchesQuery = !query || [
        employee.employeeCode,
        employee.fullName,
        employee.jobTitle,
        employee.department,
        employee.managerEmployeeCode,
        employee.contractType,
        employee.phoneNumber,
        employee.gmailEmail,
      ]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(query));
      const matchesDepartment =
        employeeDepartmentFilter === 'all' || employee.department === employeeDepartmentFilter;
      const matchesStatus =
        employeeStatusFilter === 'all' ||
        (employeeStatusFilter === 'active' ? employee.active : !employee.active);
      return matchesQuery && matchesDepartment && matchesStatus;
    });
  }, [employeeDepartmentFilter, employeeQuery, employeeStatusFilter, employees]);

  const employeeStats = useMemo(() => {
    const total = employees.length;
    const active = employees.filter((employee) => employee.active).length;
    const inactive = total - active;
    const departments = employeeDepartments.length;
    return { total, active, inactive, departments };
  }, [employees]);

  const employeesPerPage = 10;
  const employeePageCount = Math.max(1, Math.ceil(filteredEmployees.length / employeesPerPage));
  const visibleEmployees = filteredEmployees.slice(
    (employeePage - 1) * employeesPerPage,
    employeePage * employeesPerPage,
  );

  useEffect(() => {
    setEmployeePage(1);
  }, [employeeDepartmentFilter, employeeQuery, employeeStatusFilter]);

  useEffect(() => {
    setEmployeePage((current) => Math.min(current, employeePageCount));
  }, [employeePageCount]);

  const exportEmployees = () => {
    const escapeCell = (value: unknown) => `"${String(value ?? '').replace(/"/g, '""')}"`;
    const rows = [
      ['STT', 'Mã nhân viên', 'Họ và tên', 'Phòng ban', 'Mã nhân viên quản lý', 'Chức danh', 'Ngày vào làm', 'Loại hợp đồng', 'Email', 'Số điện thoại', 'Số ngày phép còn lại', 'Trạng thái'],
      ...filteredEmployees.map((employee, index) => [
        index + 1,
        employee.employeeCode,
        employee.fullName,
        employee.department,
        employee.managerEmployeeCode,
        employee.jobTitle,
        employee.hireDate ? new Date(employee.hireDate).toLocaleDateString('vi-VN') : '',
        employee.contractType,
        employee.gmailEmail,
        employee.phoneNumber,
        employee.remainingLeaveDays ?? 0,
        employee.active ? 'Đang làm việc' : 'Tạm nghỉ',
      ]),
    ];
    const csv = `\uFEFF${rows.map((row) => row.map(escapeCell).join(',')).join('\n')}`;
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    link.download = `danh-sach-nhan-vien-${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  };

  const latestPosts = useMemo(() => {
    const source = sharedContent.length ? sharedContent : contents;
    return [...source]
      .sort((a, b) => safeDateValue(b.createdAt) - safeDateValue(a.createdAt))
      .filter((item) => item.published);
  }, [contents, sharedContent]);

  const latestPostsDisplay = useMemo(
    () =>
      latestPosts.map((item) => ({
        ...item,
        cleanBody: stripHtml(item.body),
      })),
    [latestPosts],
  );

  const employeeNews = useMemo(
    () =>
      latestPostsDisplay
        .filter((item) => item.page === 'employee')
        .map((item) => ({
          ...item,
          summary: summarizeText(item.cleanBody, 90),
        })),
    [latestPostsDisplay],
  );

  const currentEmployeeCode =
    dashboard?.employeeCode || loginId || 'guest';
  const lastSeenKey = notificationStorageKey(currentEmployeeCode);
  const lastSeenAt = Number(localStorage.getItem(lastSeenKey) || '0');
  const unreadArticleCount = useMemo(
    () =>
      isAdminRoute
        ? 0
        : employeeNews.filter((item) => safeDateValue(item.createdAt) > lastSeenAt)
            .length,
    [employeeNews, isAdminRoute, lastSeenAt],
  );
  const unreadRequestCount = requestNotifications.filter((item) => !item.read).length;
  const unreadCount = unreadArticleCount + unreadRequestCount;
  const pendingAccounts = useMemo(
    () =>
      accounts.filter(
        (account) => !account.active && account.gmailVerified && !account.protected,
      ),
    [accounts],
  );

  const openAccountApprovals = () => {
    setNotificationOpen(false);
    setAdminTab('accounts');
    setError('');
    window.setTimeout(() => {
      document.getElementById('account-approvals')?.scrollIntoView({
        behavior: 'smooth',
        block: 'start',
      });
    }, 80);
  };

  const acknowledgeNews = () => {
    localStorage.setItem(lastSeenKey, String(Date.now()));
  };

  const linkedNotificationRequest = (item: RequestNotification) => {
    if (!item.requestId) return undefined;
    return [...requests, ...approvalRequests].find((request) => request.id === item.requestId);
  };

  const openRequestNotification = async (item: RequestNotification) => {
    if (!token) return;
    const request = linkedNotificationRequest(item);
    await fetch(`/api/me/requests/notifications/${encodeURIComponent(item.id)}/read`, {
      method: 'PATCH', headers: { Authorization: `Bearer ${token}` },
    });
    await refreshRequests();
    if (request) {
      setNotificationRequest(request);
      setNotificationDecision('approved');
      setNotificationDecisionNote('');
    }
    setNotificationOpen(false);
  };

  const clearAllNotifications = async () => {
    if (!token) return;
    await fetch('/api/me/requests/notifications', {
      method: 'DELETE', headers: { Authorization: `Bearer ${token}` },
    });
    acknowledgeNews();
    setRequestNotifications([]);
    setNotificationOpen(false);
  };

  const decideNotificationRequest = async () => {
    if (!token || !notificationRequest) return;
    const note = notificationDecisionNote.trim();
    if (notificationDecision === 'rejected' && note.length < 5) {
      setToast({ type: 'error', message: 'Lý do từ chối phải có ít nhất 5 ký tự.' });
      return;
    }
    setNotificationWorking(true);
    try {
      const response = await fetch(`/api/me/requests/${encodeURIComponent(notificationRequest.id)}/decision`, {
        method: 'PATCH',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: notificationDecision, note: note || undefined }),
      });
      const result = await response.json().catch(() => null) as { message?: string } | null;
      if (!response.ok) throw new Error(result?.message || 'Không xử lý được đơn');
      await refreshRequests();
      setNotificationRequest(null);
      setToast({ type: 'success', message: notificationDecision === 'approved' ? 'Đã duyệt đơn.' : 'Đã từ chối đơn.' });
    } catch (decisionError) {
      setToast({ type: 'error', message: decisionError instanceof Error ? decisionError.message : 'Không xử lý được đơn' });
    } finally {
      setNotificationWorking(false);
    }
  };

  const openArticle = (item: ContentItem) => {
    setSelectedArticle(item);
    setNotificationOpen(false);
    acknowledgeNews();
  };

  useEffect(() => {
    if (!selectedArticle) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setSelectedArticle(null);
    };
    document.addEventListener('keydown', closeOnEscape);
    document.body.classList.add('article-modal-open');
    return () => {
      document.removeEventListener('keydown', closeOnEscape);
      document.body.classList.remove('article-modal-open');
    };
  }, [selectedArticle]);

  const updateEditorBody = (body: string) => {
    setAdminForm((current) => ({
      ...current,
      body,
    }));
  };

  const syncEditorBody = () => {
    if (editorRef.current) updateEditorBody(editorRef.current.innerHTML);
  };

  const applyEditorCommand = (command: string, value?: string) => {
    if (!editorRef.current) return;
    editorRef.current.focus();
    document.execCommand(command, false, value);
    syncEditorBody();
  };

  const insertEditorLink = () => {
    const url = window.prompt('Nhập đường dẫn liên kết:');
    if (!url) return;
    const normalizedUrl = /^(https?:|mailto:|tel:)/i.test(url)
      ? url
      : `https://${url}`;
    applyEditorCommand('createLink', normalizedUrl);
  };

  const changeEditorMode = (mode: 'visual' | 'source') => {
    if (mode === editorMode) return;

    if (mode === 'source') {
      const source = editorRef.current?.innerHTML ?? adminForm.body;
      updateEditorBody(source);
      setSourceCode(source);
      setEditorMode('source');
      return;
    }

    const normalizedBody = sanitizeArticleHtml(sourceCode);
    updateEditorBody(normalizedBody);
    setEditorMode('visual');
    requestAnimationFrame(() => {
      if (editorRef.current) editorRef.current.innerHTML = normalizedBody;
    });
  };

  const insertImageFromDevice = async (file: File) => {
    setMediaUploading(true);
    const uploaded = await uploadMedia(file).finally(() => setMediaUploading(false));
    const dataUrl = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result ?? ''));
      reader.onerror = () => reject(new Error('Không đọc được ảnh'));
      reader.readAsDataURL(file);
    });

    if (editorRef.current) {
      applyEditorCommand('insertImage', uploaded.url);
      return;
    }
    setAdminForm((current) => ({
      ...current,
      body: `${current.body}\n<img src="${uploaded.url}" alt="${file.name}" />\n`,
    }));
  };

  useEffect(() => {
    if (!editorRef.current) return;
    if (document.activeElement === editorRef.current) return;
    if (editorRef.current.innerHTML !== adminForm.body) {
      editorRef.current.innerHTML = adminForm.body;
    }
  }, [adminForm.body, editingId]);

  const openImagePicker = () => {
    imageInputRef.current?.click();
  };

  useEffect(() => {
    if (isAdminRoute) return;
    if (unreadCount > 0) return;
    setNotificationOpen(false);
  }, [isAdminRoute, unreadCount]);

  const contentPageCount = Math.max(1, Math.ceil(latestPostsDisplay.length / pageSize));
  const visibleDisplayPosts = latestPostsDisplay.slice(
    (contentPage - 1) * pageSize,
    contentPage * pageSize,
  );

  const toggleEmployeeSelection = (id: string) => {
    setSelectedEmployees((current) =>
      current.includes(id)
        ? current.filter((item) => item !== id)
        : [...current, id],
    );
  };

  if (isPrivacyRoute) return <LegalPage page="privacy" />;
  if (isSupportRoute) return <LegalPage page="support" />;

  if (!isLoggedIn) {
    return (
      <main className="auth-shell">
        {toast ? (
          <div className={`app-toast app-toast-${toast.type}`} role="status" aria-live="polite">
            <span>{toast.type === 'success' ? '✓' : '!'}</span>
            <p>{toast.message}</p>
            <button type="button" onClick={() => setToast(null)} aria-label="Đóng thông báo">×</button>
          </div>
        ) : null}
        <section className="auth-card">
          <div className="brand">
            <p className="eyebrow">Sukavina Portal</p>
            <h1>
              {isAdminRoute
                ? 'Đăng nhập quản trị'
                : verificationMode
                  ? 'Xác minh Gmail'
                  : registerMode
                  ? 'Đăng ký tài khoản'
                  : 'Đăng nhập tài khoản'}
            </h1>
            <p className="lead">
              {isAdminRoute
                ? 'Vào khu quản trị để theo dõi hệ thống và điều phối dữ liệu nội bộ.'
                : verificationMode
                  ? `Nhập mã gồm 6 chữ số đã gửi tới ${registerForm.gmailEmail}.`
                  : registerMode
                  ? 'Tạo tài khoản nhân viên để sử dụng cổng thông tin nội bộ.'
                  : 'Vào hệ thống để xem số ngày phép còn lại, thông báo bảng công và bảng lương.'}
            </p>
            {isAdminRoute ? (
              <div className="login-hint-box">
                <p className="lead hint-text">
                  Khu quản trị dữ liệu cho giao diện nhân viên.
                </p>
              </div>
            ) : null}
          </div>

          {false && !isAdminRoute ? (
          <form className="auth-form" onSubmit={registrationDisabled}>
            <label>
              <span>Mã xác minh Gmail</span>
              <input
                value={verificationCode}
                readOnly
                placeholder="Nhập 6 chữ số"
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                required
              />
            </label>
            {error ? <p className="error">{error}</p> : null}
            <button type="submit" disabled={loading || verificationCode.length !== 6}>
              {loading ? 'Đang xác minh...' : 'Xác minh Gmail'}
            </button>
            <button
              type="button"
              className="auth-switch-button"
              disabled={loading}
              onClick={() => undefined}
            >
              Gửi lại mã xác minh
            </button>
            <button
              type="button"
              className="auth-switch-button"
              onClick={() => setError('')}
            >
              Quay lại thông tin đăng ký
            </button>
          </form>
          ) : registerMode && !isAdminRoute ? (
          <form className="auth-form auth-register-form" onSubmit={registrationDisabled}>
            <label>
              <span>Mã nhân viên</span>
              <input
                value={registerForm.employeeCode}
                readOnly
                placeholder="Nhập mã nhân viên"
                required
              />
            </label>
            <label>
              <span>Họ và tên</span>
              <input
                value={registerForm.fullName}
                readOnly
                placeholder="Nhập họ và tên"
                required
              />
            </label>
            <label>
              <span>Số điện thoại</span>
              <input
                value={registerForm.phoneNumber}
                readOnly
                placeholder="Nhập số điện thoại"
                inputMode="tel"
              />
            </label>
            <label>
              <span>Gmail</span>
              <input
                type="email"
                value={registerForm.gmailEmail}
                readOnly
                placeholder="name@gmail.com"
                pattern="[^@\s]+@gmail\.com"
                title="Vui lòng sử dụng địa chỉ @gmail.com"
                required
              />
            </label>
            <label>
              <span>Mật khẩu</span>
              <input
                type="password"
                value={registerForm.password}
                readOnly
                placeholder="Tối thiểu 6 ký tự"
                minLength={6}
                required
              />
            </label>
            {error ? <p className="error">{error}</p> : null}
            <button type="submit" disabled={loading}>
              {loading ? 'Đang đăng ký...' : 'Tạo tài khoản'}
            </button>
            <button
              type="button"
              className="auth-switch-button"
              onClick={() => setError('')}
            >
              Đã có tài khoản? Đăng nhập
            </button>
          </form>
          ) : (
          <form className="auth-form" onSubmit={signIn}>
            <label>
              <span>{isAdminRoute ? 'Tài khoản' : 'Mã nhân viên'}</span>
              <input
                value={loginId}
                onChange={(event) => setLoginId(event.target.value)}
                placeholder={isAdminRoute ? 'Nhập tài khoản quản trị' : 'Nhập mã nhân viên'}
                autoComplete="username"
                autoCapitalize="none"
                autoCorrect="off"
              />
            </label>

            <label>
              <span>Mật khẩu</span>
              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="••••••••"
                autoComplete="current-password"
              />
            </label>

            {error ? <p className="error">{error}</p> : null}

            <button type="submit" disabled={loading}>
              {loading ? 'Đang đăng nhập...' : 'Đăng nhập'}
            </button>
            {false ? (
              <button
                type="button"
                className="auth-switch-button"
                onClick={() => setError('')}
              >
                Đăng ký tài khoản mới
              </button>
            ) : null}
          </form>
          )}

          <PublicFooter />
        </section>
      </main>
    );
  }

  const data = dashboard ?? fallback;
  const todayAttendance = dashboard?.attendanceRecords ?? [];
  const todayCheckIn = todayAttendance.at(-1)?.punchedAt;
  const todayCheckOut = todayAttendance.length > 1 ? todayAttendance[0]?.punchedAt : null;
  const attendanceMonthOptions = Array.from({ length: 2 }, (_, index) => {
    const date = new Date();
    date.setDate(1);
    date.setMonth(date.getMonth() - index);
    const value = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
    return {
      value,
      label: new Intl.DateTimeFormat('vi-VN', { month: 'long', year: 'numeric' }).format(date),
    };
  });
  const [calendarYear, calendarMonthNumber] = attendanceMonth.split('-').map(Number);
  const calendarDayCount = new Date(calendarYear, calendarMonthNumber, 0).getDate();
  const calendarOffset = (new Date(calendarYear, calendarMonthNumber - 1, 1).getDay() + 6) % 7;
  const calendarDays = [
    ...Array.from({ length: calendarOffset }, () => null),
    ...Array.from({ length: calendarDayCount }, (_, index) => index + 1),
  ];
  const effectiveAttendanceDays =
    attendanceHistory?.month === attendanceMonth ? attendanceHistory.days : [];
  const attendanceByDate = new Map(effectiveAttendanceDays.map((day) => [day.date, day]));
  const workedMinutes = effectiveAttendanceDays.reduce((total, day) => {
    if (!day.checkIn || !day.checkOut) return total;
    return total + Math.max(0, Math.round((new Date(day.checkOut).getTime() - new Date(day.checkIn).getTime()) / 60000));
  }, 0);
  const formatMinutes = (minutes: number) => `${Math.floor(minutes / 60)} giờ ${String(minutes % 60).padStart(2, '0')} phút`;
  const averageMinutes = effectiveAttendanceDays.length
    ? Math.round(workedMinutes / effectiveAttendanceDays.length)
    : 0;

  return (
    <main className="dashboard-shell">
      <header className="topbar">
        <div className="topbar-copy">
          <p className="eyebrow">
            {isAdminRoute ? 'Sukavina Admin' : 'Sukavina Portal'}
          </p>
          <h1>{isAdminRoute ? 'Khu quản trị' : `Xin chào, ${data.name}`}</h1>
          <p className="lead">{data.role}</p>
        </div>

        <div className="topbar-actions">
          {false && isAdminRoute && canAccess('accounts.manage') ? (
            <div className="notification-wrap">
              <button
                type="button"
                className="notification-button"
                onClick={() => setNotificationOpen((current) => !current)}
                aria-label="Tài khoản mới chờ duyệt"
              >
                <span className="notification-icon">🔔</span>
                {pendingAccounts.length > 0 ? (
                  <span className="notification-badge">{pendingAccounts.length}</span>
                ) : null}
              </button>
              {notificationOpen ? (
                <div className="notification-popover admin-account-notifications">
                  <div className="notification-popover-head">
                    <strong>Tài khoản đăng ký mới</strong>
                    <button
                      type="button"
                      className="ghost-button notification-close"
                      onClick={() => setNotificationOpen(false)}
                    >
                      Đóng
                    </button>
                  </div>
                  <p className="panel-note">
                    {pendingAccounts.length
                      ? `${pendingAccounts.length} tài khoản đang chờ xác nhận.`
                      : 'Không có tài khoản nào chờ duyệt.'}
                  </p>
                  {pendingAccounts.length ? (
                    <div className="notification-list">
                      {pendingAccounts.slice(0, 5).map((account) => (
                        <article
                          className="notification-item notification-item-clickable"
                          key={account.id}
                          role="button"
                          tabIndex={0}
                          onClick={openAccountApprovals}
                          onKeyDown={(event) => {
                            if (event.key === 'Enter' || event.key === ' ') {
                              event.preventDefault();
                              openAccountApprovals();
                            }
                          }}
                        >
                          <strong>{account.fullName}</strong>
                          <p>{account.employeeCode} • Đăng ký tài khoản nhân viên</p>
                        </article>
                      ))}
                    </div>
                  ) : null}
                  <div className="notification-popover-actions">
                    <button
                      type="button"
                      onClick={openAccountApprovals}
                    >
                      Mở danh sách duyệt
                    </button>
                  </div>
                </div>
              ) : null}
            </div>
          ) : null}
          {!isAdminRoute ? (
            <div className="notification-wrap">
              <button
                type="button"
                className="notification-button"
                onClick={() => {
                  setNotificationOpen((current) => !current);
                }}
                aria-label="Thông báo nội bộ"
              >
                <span className="notification-icon">🔔</span>
                {unreadCount > 0 ? (
                  <span className="notification-badge">{unreadCount}</span>
                ) : null}
              </button>
              {notificationOpen ? (
                <div className="notification-popover">
                  <div className="notification-popover-head">
                    <div><strong>Thông báo</strong><small>{unreadCount ? `${unreadCount} chưa đọc` : 'Đã đọc tất cả'}</small></div>
                    <button
                      type="button"
                      className="ghost-button notification-close"
                      onClick={() => setNotificationOpen(false)}
                    >
                      Đóng
                    </button>
                  </div>
                  {requestNotifications.length || employeeNews.length ? (
                    <div className="notification-list">
                      {requestNotifications.map((item) => {
                        const request = linkedNotificationRequest(item);
                        const tone = request?.kind || (item.type.includes('rejected') ? 'rejected' : item.type.includes('cancelled') ? 'cancelled' : 'approved');
                        return (
                        <article
                          key={item.id}
                          className={`notification-item notification-item-clickable notification-request notification-tone-${tone} ${item.read ? '' : 'notification-unread'}`}
                          role="button" tabIndex={0}
                          onClick={() => void openRequestNotification(item)}
                          onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') void openRequestNotification(item); }}
                        >
                          <span className="notification-type-icon">{request ? requestKindIcons[request.kind] : item.type.includes('rejected') ? '×' : item.type.includes('cancelled') ? '−' : '✓'}</span>
                          <div><strong>{item.title}</strong>{request ? <span className={`notification-kind request-kind-label-${request.kind}`}>{requestKindLabels[request.kind]}</span> : null}<p>{item.message}</p><time>{new Date(item.createdAt).toLocaleString('vi-VN')}</time></div>
                          {!item.read ? <i className="notification-unread-dot" /> : null}
                        </article>
                      )})}
                      {employeeNews.map((item) => (
                        <article
                          key={item.id}
                          className={`notification-item notification-item-clickable notification-news ${safeDateValue(item.createdAt) > lastSeenAt ? 'notification-unread' : ''}`}
                          role="button"
                          tabIndex={0}
                          onClick={() => openArticle(item)}
                          onKeyDown={(event) => {
                            if (event.key === 'Enter' || event.key === ' ') openArticle(item);
                          }}
                        >
                          <span className="notification-type-icon">◆</span><div><strong>{item.title}</strong><span className="notification-kind notification-kind-news">Bài viết</span><p>{item.summary}</p><time>{new Date(item.createdAt).toLocaleString('vi-VN')}</time></div>
                        </article>
                      ))}
                    </div>
                  ) : <div className="notification-empty">Không có thông báo.</div>}
                  <div className="notification-popover-actions">
                    <button
                      type="button"
                      className="ghost-button"
                      onClick={() => void clearAllNotifications()}
                    >
                      Xóa tất cả thông báo
                    </button>
                  </div>
                </div>
              ) : null}
            </div>
          ) : null}
          <button className="ghost-button" onClick={signOut}>
            Đăng xuất
          </button>
        </div>
      </header>

      {error ? <p className="error panel-error">{error}</p> : null}
      {loading ? <p className="loading">Đang tải dữ liệu từ backend...</p> : null}
      {toast ? (
        <div className={`app-toast app-toast-${toast.type}`} role="status" aria-live="polite">
          <span>{toast.type === 'success' ? '✓' : '!'}</span>
          <p>{toast.message}</p>
          <button type="button" onClick={() => setToast(null)} aria-label="Đóng thông báo">
            ×
          </button>
        </div>
      ) : null}

      {isAdminRoute && adminTab === 'content' && canAccess('content.manage') && !contentComposerOpen ? (
        <button type="button" className="content-fab" onClick={openContentComposer} aria-label="Tạo bài viết mới">
          <span className="content-fab-icon">+</span><span className="content-fab-label">Tạo bài viết</span>
        </button>
      ) : null}

      {!isAdminRoute ? (
      <section className="dashboard-grid">
        <article className="panel panel-accent">
          <p className="panel-label">Số ngày phép còn lại</p>
          <div className="metric">{data.remainingLeaveDays}</div>
          <p className="panel-note">Ngày phép có thể dùng trong kỳ hiện tại</p>
        </article>

        <article
          className="panel news-card-clickable"
          role="button"
          tabIndex={0}
          onClick={() => setAttendanceOpen(true)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' || event.key === ' ') setAttendanceOpen(true);
          }}
        >
          <div className="panel-head">
            <div>
              <p className="panel-label">Chấm công hôm nay</p>
              <h2>{todayAttendance.length ? 'Đã ghi nhận' : 'Chưa chấm công'}</h2>
            </div>
            <span className="status-pill status-on">Xem tháng</span>
          </div>
          <div className="employee-grid">
            <div className="stat-card">
              <span className="content-meta">Giờ vào</span>
              <strong>{formatAttendanceTime(todayCheckIn)}</strong>
            </div>
            <div className="stat-card">
              <span className="content-meta">Giờ ra</span>
              <strong>{formatAttendanceTime(todayCheckOut)}</strong>
            </div>
          </div>
        </article>

        <article className="panel">
          <p className="panel-label">Thông báo bảng lương</p>
          <h2>{data.payrollStatus}</h2>
          <p className="panel-note">
            Xem trạng thái phát hành lương và các ghi chú liên quan.
          </p>
        </article>

        <article className="panel panel-wide request-panel">
          <div className="panel-head request-panel-head">
            <div>
              <p className="panel-label">Đơn từ</p>
              <h2>Đơn từ của tôi</h2>
              <p className="panel-note">Theo dõi nghỉ phép, đi trễ, về sớm, làm thêm giờ và công tác.</p>
            </div>
          </div>
          <div className="request-filters" role="group" aria-label="Lọc trạng thái đơn">
            {([
              ['all', 'Tất cả'],
              ['pending', 'Chờ duyệt'],
              ['approved', 'Đã duyệt'],
              ['rejected', 'Từ chối'],
              ['cancelled', 'Đã hủy'],
            ] as const).map(([value, label]) => (
              <button
                type="button"
                key={value}
                className={requestFilter === value ? 'active' : ''}
                onClick={() => setRequestFilter(value)}
              >
                {label}
              </button>
            ))}
          </div>
          <div className="request-list">
            {requests.filter((item) => requestFilter === 'all' || item.status === requestFilter).length ? (
              requests
                .filter((item) => requestFilter === 'all' || item.status === requestFilter)
                .map((item) => (
                  <article className={`request-item request-item-${item.kind}`} key={item.id}>
                    <div className="request-item-main">
                      <div className={`request-kind-icon request-kind-${item.kind}`} aria-hidden="true">
                        {requestKindIcons[item.kind]}
                      </div>
                      <div>
                        <div className="request-title-line">
                          <h3 className={`request-kind-label request-kind-label-${item.kind}`}>{requestKindLabels[item.kind]}</h3>
                          <span className={`request-status request-status-${item.status}`}>{requestStatusLabels[item.status]}</span>
                        </div>
                        <p className="request-time">
                          {new Date(item.startsAt).toLocaleString('vi-VN')} – {new Date(item.endsAt).toLocaleString('vi-VN')}
                        </p>
                        <p className="request-reason">{item.reason}</p>
                      </div>
                    </div>
                    {item.status === 'pending' ? (
                      <button type="button" className="request-cancel" onClick={() => void cancelRequest(item.id)}>Hủy đơn</button>
                    ) : null}
                  </article>
                ))
            ) : (
              <div className="request-empty"><span>▤</span><strong>Chưa có đơn trong mục này</strong><p>Nhấn dấu + để tạo đơn mới.</p></div>
            )}
          </div>
        </article>

      </section>
      ) : null}

      {notificationRequest ? (
        <div className="article-modal-backdrop request-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !notificationWorking) setNotificationRequest(null); }}>
          <section className="article-modal request-notification-modal" role="dialog" aria-modal="true" aria-labelledby="request-notification-title">
            <header className="request-notification-header">
              <span className={`request-kind-icon request-kind-${notificationRequest.kind}`}>{requestKindIcons[notificationRequest.kind]}</span>
              <div><span className={`notification-kind request-kind-label-${notificationRequest.kind}`}>{requestKindLabels[notificationRequest.kind]}</span><h2 id="request-notification-title">{notificationRequest.employee?.fullName || 'Chi tiết đơn từ'}</h2></div>
              <button type="button" className="request-modal-close" onClick={() => setNotificationRequest(null)}>×</button>
            </header>
            <div className="request-notification-body">
              <div className="request-notification-meta"><span><small>Từ</small>{new Date(notificationRequest.startsAt).toLocaleString('vi-VN')}</span><span><small>Đến</small>{new Date(notificationRequest.endsAt).toLocaleString('vi-VN')}</span></div>
              <div className="request-notification-reason"><small>Lý do</small><p>{notificationRequest.reason}</p></div>
              {notificationRequest.decisionNote ? <div className="request-notification-note"><small>Ghi chú xử lý</small><p>{notificationRequest.decisionNote}</p></div> : null}
              <span className={`request-status request-status-${notificationRequest.status}`}>{requestStatusLabels[notificationRequest.status]}</span>
              {notificationRequest.status === 'pending' && approvalRequests.some((item) => item.id === notificationRequest.id) ? (
                <div className="request-decision-box">
                  <div className="request-decision-tabs"><button type="button" className={notificationDecision === 'approved' ? 'active approved' : ''} onClick={() => setNotificationDecision('approved')}>Duyệt đơn</button><button type="button" className={notificationDecision === 'rejected' ? 'active rejected' : ''} onClick={() => setNotificationDecision('rejected')}>Từ chối</button></div>
                  <label><span>{notificationDecision === 'rejected' ? 'Lý do từ chối (bắt buộc)' : 'Ghi chú cho nhân viên (tùy chọn)'}</span><textarea value={notificationDecisionNote} onChange={(event) => setNotificationDecisionNote(event.target.value)} placeholder={notificationDecision === 'rejected' ? 'Nhập lý do từ chối...' : 'Thêm ghi chú nếu cần...'} /></label>
                  <button type="button" className={`request-decision-submit ${notificationDecision}`} disabled={notificationWorking} onClick={() => void decideNotificationRequest()}>{notificationWorking ? 'Đang xử lý...' : notificationDecision === 'approved' ? 'Xác nhận duyệt' : 'Xác nhận từ chối'}</button>
                </div>
              ) : null}
            </div>
          </section>
        </div>
      ) : null}

      {requestComposerOpen ? (
        <div
          className="article-modal-backdrop request-modal-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget && !requestSubmitting) setRequestComposerOpen(false);
          }}
        >
          <form className="article-modal request-composer" role="dialog" aria-modal="true" aria-labelledby="request-composer-title" onSubmit={submitRequest}>
            <header className="request-composer-header">
              <div className="request-composer-mark" aria-hidden="true">＋</div>
              <div>
                <p className="panel-label">Sukavina Portal</p>
                <h2 id="request-composer-title">Tạo đơn mới</h2>
                <p>Gửi yêu cầu đến bộ phận quản lý nhanh chóng và minh bạch.</p>
              </div>
              <button type="button" className="request-modal-close" disabled={requestSubmitting} onClick={() => setRequestComposerOpen(false)} aria-label="Đóng">×</button>
            </header>
            <div className="request-form-body">
              <fieldset className="request-kind-picker">
                <legend>Chọn loại đơn</legend>
                <div>
                  {(Object.keys(requestKindLabels) as EmployeeRequest['kind'][]).map((kind) => (
                    <button type="button" className={requestForm.kind === kind ? 'active' : ''} onClick={() => setRequestForm((current) => ({ ...current, kind }))} key={kind}>
                      <span aria-hidden="true">{kind === 'leave' ? '☀' : kind === 'late' ? '◷' : kind === 'early' ? '↗' : kind === 'overtime' ? '☾' : '✈'}</span>
                      <strong>{requestKindLabels[kind]}</strong>
                    </button>
                  ))}
                </div>
              </fieldset>
              <label className="request-field"><span><i>1</i> Từ ngày / giờ</span><input required type="datetime-local" value={requestForm.startsAt} onChange={(event) => setRequestForm((current) => ({ ...current, startsAt: event.target.value }))} /></label>
              <label className="request-field"><span><i>2</i> Đến ngày / giờ</span><input required type="datetime-local" min={requestForm.startsAt} value={requestForm.endsAt} onChange={(event) => setRequestForm((current) => ({ ...current, endsAt: event.target.value }))} /></label>
              <label className="request-field request-field-wide">
                <span><i>3</i> Lý do</span>
                <textarea required minLength={10} maxLength={1000} rows={4} placeholder="Nhập lý do, tối thiểu 10 ký tự..." value={requestForm.reason} onChange={(event) => setRequestForm((current) => ({ ...current, reason: event.target.value }))} />
                <small className={requestForm.reason.trim().length >= 10 ? 'valid' : ''}>{requestForm.reason.trim().length}/1000 ký tự · Tối thiểu 10 ký tự</small>
              </label>
            </div>
            <footer className="request-form-actions">
              <button type="button" className="ghost-button" disabled={requestSubmitting} onClick={() => setRequestComposerOpen(false)}>Hủy</button>
              <button type="submit" className="primary-button" disabled={requestSubmitting || requestForm.reason.trim().length < 10 || !requestForm.startsAt || !requestForm.endsAt}>
                {requestSubmitting ? 'Đang gửi...' : 'Gửi đơn →'}
              </button>
            </footer>
          </form>
        </div>
      ) : null}

      {!isAdminRoute && isLoggedIn ? (
        <button type="button" className="request-fab" onClick={openRequestComposer} aria-label="Tạo đơn mới">
          <span className="request-fab-icon">+</span><span className="request-fab-label">Tạo đơn</span>
        </button>
      ) : null}

      {attendanceOpen ? (
        <div
          className="article-modal-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setAttendanceOpen(false);
          }}
        >
          <article className="article-modal attendance-calendar-modal" role="dialog" aria-modal="true" aria-labelledby="attendance-title">
            <header className="article-modal-header">
              <div>
                <p className="panel-label">Lịch sử chấm công</p>
                <h2 id="attendance-title">Bảng giờ chấm công tháng {String(calendarMonthNumber).padStart(2, '0')}/{calendarYear}</h2>
              </div>
              <button type="button" className="ghost-button" onClick={() => setAttendanceOpen(false)}>Đóng</button>
            </header>
            <div className="article-modal-content attendance-calendar-content">
              <label className="attendance-month-picker">
                <span>Chọn tháng</span>
                <select value={attendanceMonth} onChange={(event) => setAttendanceMonth(event.target.value)}>
                  {attendanceMonthOptions.map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>
              </label>
              {attendanceLoading ? <p className="loading">Đang tải bảng công...</p> : null}
              <div className="attendance-summary-grid">
                <div className="attendance-summary-card"><span>Tổng giờ làm việc</span><strong>{formatMinutes(workedMinutes)}</strong></div>
                <div className="attendance-summary-card"><span>Số ngày công</span><strong>{effectiveAttendanceDays.length} ngày</strong></div>
                <div className="attendance-summary-card"><span>Trung bình/ngày</span><strong>{formatMinutes(averageMinutes)}</strong></div>
                <div className="attendance-summary-card"><span>Ngày không ghi nhận</span><strong>{calendarDayCount - effectiveAttendanceDays.length} ngày</strong></div>
              </div>
              <div className="attendance-weekdays">
                {['Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7', 'Chủ nhật'].map((weekday) => <strong key={weekday}>{weekday}</strong>)}
              </div>
              <div className="attendance-calendar-grid">
                {calendarDays.map((day, index) => {
                  if (!day) return <div className="attendance-day attendance-day-empty" key={`empty-${index}`} />;
                  const date = `${attendanceMonth}-${String(day).padStart(2, '0')}`;
                  const attendanceDay = attendanceByDate.get(date);
                  const weekdayIndex = index % 7;
                  const isWeekend = weekdayIndex >= 5;
                  return (
                    <div className={`attendance-day${isWeekend ? ' attendance-day-weekend' : ''}`} key={date}>
                      <div className="attendance-day-head"><strong>{day}</strong><span>{attendanceDay?.punchCount ?? 0} lượt</span></div>
                      {attendanceDay ? (
                        <>
                          <div className="attendance-time attendance-time-in"><span>Vào</span><strong>{formatAttendanceTime(attendanceDay.checkIn)}</strong></div>
                          <div className="attendance-time attendance-time-out"><span>Ra</span><strong>{formatAttendanceTime(attendanceDay.checkOut)}</strong></div>
                          <small>{formatMinutes(
                            attendanceDay.checkIn && attendanceDay.checkOut
                              ? Math.max(0, Math.round((new Date(attendanceDay.checkOut).getTime() - new Date(attendanceDay.checkIn).getTime()) / 60000))
                              : 0,
                          )}</small>
                          <div className="attendance-punches">
                            {attendanceDay.punches.map((punch) => <span key={punch.id}>{formatAttendanceTime(punch.punchedAt)} · {punch.source}</span>)}
                          </div>
                        </>
                      ) : (
                        <p>{isWeekend ? 'Nghỉ' : 'Chưa ghi nhận'}</p>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          </article>
        </div>
      ) : null}

      {selectedArticle ? (
        <div
          className="article-modal-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setSelectedArticle(null);
          }}
        >
          <article className="article-modal" role="dialog" aria-modal="true" aria-labelledby="article-modal-title">
            <header className="article-modal-header">
              <div>
                <p className="content-meta">#{selectedArticle.sortOrder}</p>
                <h2 id="article-modal-title">{selectedArticle.title}</h2>
              </div>
              <button type="button" className="ghost-button" onClick={() => setSelectedArticle(null)}>
                Đóng
              </button>
            </header>
            <div
              className="article-modal-content"
              dangerouslySetInnerHTML={{ __html: sanitizeArticleHtml(selectedArticle.body) }}
            />
          </article>
        </div>
      ) : null}

      {isAdminRoute ? (
        <section className="admin-layout">
          <aside className="admin-nav panel">
            <p className="panel-label">Quản trị</p>
            {canAccess('content.manage') ? (
            <button
              type="button"
              className={adminTab === 'content' ? 'active' : ''}
              onClick={() => setAdminTab('content')}
            >
              Bài viết
            </button>
            ) : null}
            {canAccess('employees.manage') ? (
            <button
              type="button"
              className={adminTab === 'employees' ? 'active' : ''}
              onClick={() => setAdminTab('employees')}
            >
              Nhân viên
            </button>
            ) : null}
            {canAccess('accounts.manage') ? (
              <button
                type="button"
                className={adminTab === 'accounts' ? 'active' : ''}
                onClick={() => setAdminTab('accounts')}
              >
                Phân quyền
              </button>
            ) : null}
            {!isSuperAdmin && currentUser && currentUser.permissions.length === 0 ? (
              <p className="panel-note">Tài khoản chưa được cấp chức năng quản trị.</p>
            ) : null}
          </aside>

          <section className="admin-main">
            {adminTab === 'employees' && canAccess('employees.manage') ? (
              <section className="employee-hub panel panel-employee-hub">
                <div className="employee-hero">
                  <div>
                    <p className="panel-label">Danh sách nhân viên</p>
                    <h2>Quản lý thông tin nhân viên</h2>
                    <p className="panel-note">
                      Theo dõi hồ sơ, phòng ban và trạng thái làm việc trong một giao diện thống nhất.
                    </p>
                  </div>
                  <div className="employee-toolbar">
                    <button
                      type="button"
                      className="ghost-button employee-export-button"
                      onClick={exportEmployees}
                    >
                      Xuất Excel
                    </button>
                    <button
                      type="button"
                      className="employee-add-button"
                      onClick={() => {
                        setEditingEmployeeId(null);
                        document.getElementById('employee-form-card')?.scrollIntoView({ behavior: 'smooth' });
                      }}
                    >
                      + Thêm nhân viên
                    </button>
                  </div>
                </div>

                <div className="employee-stats employee-stats-hero">
                  <article className="stat-card stat-card-primary">
                    <span>Tổng nhân viên</span>
                    <strong>{employeeStats.total}</strong>
                    <p>Hồ sơ hiện có trong hệ thống</p>
                  </article>
                  <article className="stat-card">
                    <span>Đang hoạt động</span>
                    <strong>{employeeStats.active}</strong>
                    <p>Có thể đăng nhập và thao tác</p>
                  </article>
                  <article className="stat-card">
                    <span>Tạm nghỉ</span>
                    <strong>{employeeStats.inactive}</strong>
                    <p>Tài khoản đang ngừng hoạt động</p>
                  </article>
                  <article className="stat-card">
                    <span>Phòng ban</span>
                    <strong>{employeeStats.departments}</strong>
                    <p>Đơn vị đang có nhân sự</p>
                  </article>
                </div>

                <div className="employee-workspace">
                  <form id="employee-form-card" className="admin-form panel employee-form-card" onSubmit={saveEmployee}>
                    <div className="panel-head panel-head-stack">
                      <div>
                        <p className="panel-label">
                          {editingEmployeeId ? 'Chỉnh sửa hồ sơ' : 'Thêm nhân viên mới'}
                        </p>
                        <h3>Thông tin nhân viên</h3>
                      </div>
                      {editingEmployeeId ? (
                        <span className="status-pill status-on">Đang chỉnh sửa</span>
                      ) : (
                        <span className="status-pill">Tạo mới</span>
                      )}
                    </div>

                    <div className="employee-form-grid">
                      <label>
                        <span>Mã nhân viên</span>
                        <input
                          value={employeeForm.employeeCode}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              employeeCode: event.target.value,
                            }))
                          }
                          placeholder="SKV-002"
                        />
                      </label>
                      <label>
                        <span>Họ và tên</span>
                        <input
                          value={employeeForm.fullName}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              fullName: event.target.value,
                            }))
                          }
                          placeholder="Trần Văn B"
                        />
                      </label>
                      <label>
                        <span>Phòng ban</span>
                        <input
                          value={employeeForm.department}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              department: event.target.value,
                            }))
                          }
                          placeholder="Hành chính"
                        />
                      </label>
                      <label>
                        <span>Mã nhân viên quản lý</span>
                        <input
                          value={employeeForm.managerEmployeeCode}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              managerEmployeeCode: event.target.value,
                            }))
                          }
                          placeholder="SKV-001"
                        />
                      </label>
                      <label>
                        <span>Chức danh</span>
                        <input
                          value={employeeForm.jobTitle}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              jobTitle: event.target.value,
                            }))
                          }
                          placeholder="Nhân viên"
                        />
                      </label>
                      <label>
                        <span>Ngày vào làm</span>
                        <input
                          type="date"
                          value={employeeForm.hireDate}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              hireDate: event.target.value,
                            }))
                          }
                        />
                      </label>
                      <label>
                        <span>Loại hợp đồng</span>
                        <select
                          value={employeeForm.contractType}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              contractType: event.target.value,
                            }))
                          }
                        >
                          <option value="">Chọn loại hợp đồng</option>
                          <option value="Thử việc">Thử việc</option>
                          <option value="Xác định thời hạn">Xác định thời hạn</option>
                          <option value="Không xác định thời hạn">Không xác định thời hạn</option>
                          <option value="Thời vụ">Thời vụ</option>
                        </select>
                      </label>
                      <label>
                        <span>Email</span>
                        <input
                          type="email"
                          value={employeeForm.gmailEmail}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              gmailEmail: event.target.value,
                            }))
                          }
                          placeholder="name@gmail.com"
                        />
                      </label>
                      <label>
                        <span>Số điện thoại</span>
                        <input
                          type="tel"
                          value={employeeForm.phoneNumber}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              phoneNumber: event.target.value,
                            }))
                          }
                          placeholder="0900000002"
                        />
                      </label>
                      <label>
                        <span>Số ngày phép còn lại</span>
                        <input
                          type="number"
                          min="0"
                          step="1"
                          value={employeeForm.remainingLeaveDays}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              remainingLeaveDays: Math.max(0, Number(event.target.value) || 0),
                            }))
                          }
                          placeholder="0"
                        />
                      </label>
                      <label>
                        <span>Mật khẩu đăng nhập</span>
                        <input
                          type="password"
                          value={employeeForm.password}
                          onChange={(event) =>
                            setEmployeeForm((current) => ({
                              ...current,
                              password: event.target.value,
                            }))
                          }
                          placeholder={editingEmployeeId ? 'Để trống nếu không đổi' : 'Nhập mật khẩu'}
                        />
                      </label>
                    </div>

                    <label className="checkbox-row">
                      <input
                        type="checkbox"
                        checked={employeeForm.active}
                        onChange={(event) =>
                          setEmployeeForm((current) => ({
                            ...current,
                            active: event.target.checked,
                          }))
                        }
                      />
                      <span>Kích hoạt tài khoản</span>
                    </label>

                    <div className="form-actions">
                      <button type="submit" disabled={loading}>
                        {editingEmployeeId ? 'Cập nhật hồ sơ' : 'Thêm nhân viên'}
                      </button>
                      <button
                        type="button"
                        className="ghost-button"
                        onClick={() => {
                          setEditingEmployeeId(null);
                          setEmployeeForm({
                            employeeCode: '',
                            fullName: '',
                            jobTitle: '',
                            department: '',
                            managerEmployeeCode: '',
                            hireDate: '',
                            contractType: '',
                            phoneNumber: '',
                            gmailEmail: '',
                            password: '',
                            authProvider: 'phone_password',
                            remainingLeaveDays: 0,
                            attendanceStatus: '',
                            payrollStatus: '',
                            active: true,
                          });
                        }}
                      >
                        Làm mới
                      </button>
                    </div>
                  </form>

                  <section className="panel employee-list-card">
                    <div className="panel-head panel-head-stack">
                      <div>
                        <p className="panel-label">Bảng nhân viên</p>
                        <h3>Danh sách hiện tại</h3>
                        <p className="panel-note">
                          Kết quả lọc: {filteredEmployees.length} / {employees.length}
                        </p>
                      </div>
                      <div className="employee-pill-row">
                        <span className="status-pill">
                          Chọn: {selectedEmployees.length}
                        </span>
                        <button type="button" className="ghost-button employee-refresh-button" onClick={() => refreshEmployees()}>
                          Tải lại
                        </button>
                      </div>
                    </div>

                    <div className="employee-filter-bar">
                      <select
                        value={employeeDepartmentFilter}
                        onChange={(event) => setEmployeeDepartmentFilter(event.target.value)}
                        aria-label="Lọc theo phòng ban"
                      >
                        <option value="all">Tất cả phòng ban</option>
                        {employeeDepartments.map((department) => (
                          <option key={department} value={department}>{department}</option>
                        ))}
                      </select>
                      <select
                        value={employeeStatusFilter}
                        onChange={(event) => setEmployeeStatusFilter(event.target.value)}
                        aria-label="Lọc theo trạng thái"
                      >
                        <option value="all">Tất cả trạng thái</option>
                        <option value="active">Đang làm việc</option>
                        <option value="inactive">Tạm nghỉ</option>
                      </select>
                      <div className="search-box employee-search">
                        <input
                          value={employeeQuery}
                          onChange={(event) => setEmployeeQuery(event.target.value)}
                          placeholder="Tìm tên, mã nhân viên, Gmail..."
                        />
                      </div>
                    </div>

                    <div className="employee-table-shell">
                      <div className="employee-table employee-table-modern">
                        <div className="employee-table-head">
                          <span>#</span>
                          <span>Nhân viên</span>
                          <span>Mã nhân viên</span>
                          <span>Phòng ban</span>
                          <span>Chức vụ</span>
                          <span>Trạng thái</span>
                          <span className="employee-actions-head">Hành động</span>
                        </div>
                        {visibleEmployees.length ? (
                          visibleEmployees.map((employee, index) => (
                            <article key={employee.id} className="employee-row employee-row-modern">
                              <div className="employee-cell employee-index">
                                {(employeePage - 1) * employeesPerPage + index + 1}
                              </div>
                              <div className="employee-cell employee-person">
                                <div className="employee-avatar">
                                  {(employee.fullName || '?')
                                    .split(' ')
                                    .slice(0, 2)
                                    .map((part: string) => part[0])
                                    .join('')
                                    .toUpperCase()}
                                </div>
                                <div>
                                  <h3>{employee.fullName}</h3>
                                  <p>{employee.gmailEmail || employee.phoneNumber || 'Chưa có thông tin liên hệ'}</p>
                                </div>
                              </div>
                              <div className="employee-cell employee-code" data-label="Mã nhân viên">
                                <span>{employee.employeeCode}</span>
                              </div>
                              <div className="employee-cell employee-muted" data-label="Phòng ban">
                                <span className="employee-department-badge">{employee.department || 'Chưa cập nhật'}</span>
                              </div>
                              <div className="employee-cell employee-muted" data-label="Chức vụ">
                                <span>{employee.jobTitle || 'Chưa cập nhật'}</span>
                                <small>
                                  {employee.contractType || 'Chưa có hợp đồng'}
                                  {' · '}
                                  {employee.hireDate ? new Date(employee.hireDate).toLocaleDateString('vi-VN') : 'Chưa có ngày vào làm'}
                                </small>
                              </div>
                              <div className="employee-cell employee-status-cell" data-label="Trạng thái">
                                <span
                                  className={
                                    employee.active
                                      ? 'status-pill status-on'
                                      : 'status-pill status-off'
                                  }
                                >
                                  {employee.active ? 'Đang làm việc' : 'Tạm nghỉ'}
                                </span>
                                <small>{employee.remainingLeaveDays ?? 0} ngày phép</small>
                              </div>
                              <div className="employee-cell employee-actions-row employee-row-actions">
                                <button type="button" onClick={() => editEmployee(employee)}>
                                  Sửa
                                </button>
                                {employee.protected || employee.accountType === 'SUPER_ADMIN' ? (
                                  <span className="employee-protected-badge">Được bảo vệ</span>
                                ) : (
                                  <button
                                    type="button"
                                    className="ghost-button employee-delete-button"
                                    onClick={() => deleteEmployee(employee.id)}
                                  >
                                    Xóa
                                  </button>
                                )}
                              </div>
                            </article>
                          ))
                        ) : (
                          <div className="employee-empty-state">
                            <strong>Không có nhân viên phù hợp</strong>
                            <p>Thử đổi từ khóa tìm kiếm hoặc tạo thêm nhân viên mới.</p>
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="employee-pagination">
                      <span>
                        Hiển thị {filteredEmployees.length ? (employeePage - 1) * employeesPerPage + 1 : 0}
                        {' - '}{Math.min(employeePage * employeesPerPage, filteredEmployees.length)} trong {filteredEmployees.length} nhân viên
                      </span>
                      <div>
                        <button type="button" className="ghost-button" disabled={employeePage === 1} onClick={() => setEmployeePage((page) => page - 1)}>Trước</button>
                        <strong>{employeePage} / {employeePageCount}</strong>
                        <button type="button" className="ghost-button" disabled={employeePage === employeePageCount} onClick={() => setEmployeePage((page) => page + 1)}>Sau</button>
                      </div>
                    </div>
                  </section>
                </div>
              </section>
            ) : null}

            {adminTab === 'accounts' && canAccess('accounts.manage') ? (
              <section className="panel access-panel" id="account-approvals">
                <div className="panel-head">
                  <div>
                    <p className="panel-label">Phân quyền tài khoản</p>
                    <h2>Tài khoản quản trị</h2>
                    <p className="panel-note">
                      Admin tổng luôn có toàn quyền và không thể xóa hoặc hạ cấp.
                      Admin thường chỉ thấy các menu đã được cấp.
                    </p>
                  </div>
                  <div className="access-head-actions"><button type="button" className="primary-button" onClick={() => setAdminAccountPickerOpen(true)}>＋ Thêm tài khoản admin</button><button type="button" className="ghost-button" onClick={() => refreshAccounts()}>Tải lại</button></div>
                </div>

                {[
                  {
                    title: 'Tài khoản Admin',
                    className: '',
                    emptyMessage: 'Chưa có tài khoản admin nào.',
                    items: accounts.filter(
                      (account) =>
                        account.active &&
                        account.savedAccountType !== 'EMPLOYEE',
                    ),
                  },
                ].map((group) => (
                  <div className={`access-group ${group.className}`} key={group.title}>
                    <div className="access-group-head">
                      <h3>{group.title}</h3>
                      <span className="status-pill">{group.items.length} tài khoản</span>
                    </div>
                    <div className="access-list">
                      {group.items.length ? group.items.map((account) => (
                        <article className="access-card" key={account.id}>
                          <div className="access-identity">
                            <div className="employee-avatar">
                              {(account.fullName || '?')
                                .split(' ')
                                .slice(-2)
                                .map((part) => part[0])
                                .join('')
                                .toUpperCase()}
                            </div>
                            <div>
                              <h3>{account.fullName}</h3>
                              <p>{account.employeeCode} • {account.department}</p>
                            </div>
                            {account.protected ? (
                              <span className="status-pill status-on">Admin tổng • Được bảo vệ</span>
                            ) : !account.gmailVerified ? (
                              <span className="status-pill status-off">Chưa xác minh Gmail</span>
                            ) : account.active ? (
                              <span className="status-pill status-on">Đã xác nhận</span>
                            ) : (
                              <span className="status-pill status-off">Chờ duyệt</span>
                            )}
                          </div>

                          <div className="access-role-row">
                            <label>
                              <span>Loại tài khoản</span>
                              <select
                                value={account.accountType ?? 'EMPLOYEE'}
                                disabled={account.protected}
                                onChange={(event) =>
                                  updateAccountDraft(account.id, {
                                    accountType: event.target.value as 'ADMIN' | 'EMPLOYEE',
                                    permissions:
                                      event.target.value === 'ADMIN' ? account.permissions ?? [] : [],
                                  })
                                }
                              >
                                {account.protected ? <option value="SUPER_ADMIN">Admin tổng</option> : <option value="ADMIN">Admin thường</option>}
                              </select>
                            </label>
                          </div>

                          <div className="permission-grid">
                            {permissionOptions.map((permission) => (
                              <label className="permission-option" key={permission.key}>
                                <input
                                  type="checkbox"
                                  checked={
                                    account.protected ||
                                    account.permissions?.includes(permission.key) === true
                                  }
                                  disabled={account.protected || account.accountType !== 'ADMIN'}
                                  onChange={(event) => {
                                    const currentPermissions = account.permissions ?? [];
                                    updateAccountDraft(account.id, {
                                      permissions: event.target.checked
                                        ? [...new Set([...currentPermissions, permission.key])]
                                        : currentPermissions.filter((item) => item !== permission.key),
                                    });
                                  }}
                                />
                                <span>
                                  <strong>{permission.label}</strong>
                                  <small>{permission.description}</small>
                                </span>
                              </label>
                            ))}
                          </div>

                          <div className="access-actions">
                            <button
                              type="button"
                              disabled={loading || account.protected}
                              onClick={() => saveAccountAccess(account)}
                            >
                              {account.protected ? 'Không thể thay đổi' : 'Lưu phân quyền'}
                            </button>
                          </div>
                        </article>
                      )) : (
                        <div className="access-empty-state">
                          <p>{group.emptyMessage}</p>
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </section>
            ) : null}

            {adminTab === 'content' && canAccess('content.manage') ? (
              <>
                {contentComposerOpen ? createPortal(
                  <div
                    className="article-modal-backdrop content-composer-backdrop"
                    role="presentation"
                    onMouseDown={(event) => {
                      if (event.target === event.currentTarget) closeContentComposer();
                    }}
                  >
                  <form className="admin-form content-composer" onSubmit={saveContent} onMouseDown={(event) => event.stopPropagation()} role="dialog" aria-modal="true" aria-labelledby="content-composer-title">
                    <header className="content-composer-header">
                      <div className="content-composer-mark" aria-hidden="true">✦</div>
                      <div>
                        <p className="panel-label">Sukavina Admin</p>
                        <h2 id="content-composer-title">{editingId ? 'Chỉnh sửa bài viết' : 'Tạo bài viết mới'}</h2>
                        <p>Soạn nội dung nội bộ rõ ràng, trực quan và chuyên nghiệp.</p>
                      </div>
                      <button type="button" className="content-composer-close" onClick={closeContentComposer} disabled={loading} aria-label="Đóng">×</button>
                    </header>
                    <div className="content-composer-body">
                  <label className="content-title-field">
                    <span>Tiêu đề bài viết</span>
                    <input
                      value={adminForm.title}
                      onChange={(event) =>
                        setAdminForm((current) => ({ ...current, title: event.target.value }))
                      }
                      placeholder="Nhập tiêu đề ngắn gọn và dễ hiểu..."
                      required
                    />
                  </label>
                  <label>
                    <span>Mã bài viết</span>
                    <input
                      value={adminForm.key}
                      onChange={(event) =>
                        setAdminForm((current) => ({
                          ...current,
                          key: event.target.value,
                        }))
                      }
                      placeholder="Ví dụ: thong-bao-thang-7"
                      required
                    />
                  </label>
                  <div className="editor-field">
                    <span>Nội dung</span>
                    <div className="editor-shell">
                      <div className="editor-toolbar" role="toolbar" aria-label="Thanh công cụ soạn nội dung">
                        <div className="editor-tool-group editor-mode-group">
                          <button
                            type="button"
                            className={editorMode === 'visual' ? 'active' : ''}
                            onClick={() => changeEditorMode('visual')}
                          >
                            Soạn thảo
                          </button>
                          <button
                            type="button"
                            className={editorMode === 'source' ? 'active' : ''}
                            onClick={() => changeEditorMode('source')}
                          >
                            Mã nguồn
                          </button>
                        </div>
                        {editorMode === 'visual' ? (
                          <>
                        <div className="editor-tool-group">
                          <button type="button" title="Hoàn tác" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('undo'); }}>↶</button>
                          <button type="button" title="Làm lại" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('redo'); }}>↷</button>
                        </div>
                        <div className="editor-tool-group editor-format-group">
                          <select
                            aria-label="Kiểu đoạn văn"
                            defaultValue="p"
                            onChange={(event) => {
                              applyEditorCommand('formatBlock', event.target.value);
                              event.target.value = 'p';
                            }}
                          >
                            <option value="p">Đoạn văn</option>
                            <option value="h2">Tiêu đề lớn</option>
                            <option value="h3">Tiêu đề nhỏ</option>
                            <option value="blockquote">Trích dẫn</option>
                          </select>
                        </div>
                        <div className="editor-tool-group">
                          <button type="button" className="editor-tool-bold" title="In đậm" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('bold'); }}>B</button>
                          <button type="button" className="editor-tool-italic" title="In nghiêng" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('italic'); }}>I</button>
                          <button type="button" className="editor-tool-underline" title="Gạch chân" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('underline'); }}>U</button>
                        </div>
                        <div className="editor-tool-group">
                          <button type="button" title="Danh sách dấu chấm" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('insertUnorderedList'); }}>• Danh sách</button>
                          <button type="button" title="Danh sách đánh số" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('insertOrderedList'); }}>1. Danh sách</button>
                        </div>
                        <div className="editor-tool-group">
                          <button type="button" title="Căn trái" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('justifyLeft'); }}>≡</button>
                          <button type="button" title="Căn giữa" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('justifyCenter'); }}>≣</button>
                          <button type="button" title="Căn phải" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('justifyRight'); }}>≡</button>
                        </div>
                        <div className="editor-tool-group">
                          <button type="button" title="Chèn liên kết" onMouseDown={(event) => { event.preventDefault(); insertEditorLink(); }}>Liên kết</button>
                          <button type="button" title="Xóa liên kết đang chọn" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('unlink'); }}>Xóa liên kết</button>
                          <button type="button" title="Xóa định dạng" onMouseDown={(event) => { event.preventDefault(); applyEditorCommand('removeFormat'); }}>Xóa định dạng</button>
                          <button type="button" className="editor-image-button" onClick={openImagePicker}>Chèn ảnh</button>
                        </div>
                          </>
                        ) : null}
                      </div>
                      <input
                        ref={imageInputRef}
                        type="file"
                        accept="image/*"
                        className="editor-file-input"
                        onChange={async (event) => {
                          const file = event.target.files?.[0];
                          if (!file) return;
                          try {
                            await insertImageFromDevice(file);
                          } catch (uploadError) {
                            setError(uploadError instanceof Error ? uploadError.message : 'Không chèn được ảnh');
                          } finally {
                            event.target.value = '';
                          }
                          }}
                        />
                      {editorMode === 'visual' ? (
                        <div
                          ref={editorRef}
                          className="editor-canvas editor-canvas-doc editor-rich"
                          contentEditable
                          suppressContentEditableWarning
                          spellCheck
                          data-placeholder="Nhập nội dung bài viết ở đây..."
                          onFocus={() => setError('')}
                          onInput={(event) =>
                            updateEditorBody((event.currentTarget as HTMLDivElement).innerHTML)
                          }
                          onBlur={(event) =>
                            updateEditorBody((event.currentTarget as HTMLDivElement).innerHTML)
                          }
                        />
                      ) : (
                        <div className="editor-source-wrap">
                          <textarea
                            className="editor-source"
                            value={sourceCode}
                            spellCheck={false}
                            placeholder="Dán mã HTML vào đây..."
                            onChange={(event) => setSourceCode(event.target.value)}
                          />
                        </div>
                      )}
                    </div>
                  </div>
                  <label>
                    <span>Thứ tự</span>
                    <input
                      type="number"
                      value={adminForm.sortOrder}
                      onChange={(event) => {
                          setAutoSortOrder(false);
                          setAdminForm((current) => ({
                            ...current,
                            sortOrder: Number(event.target.value),
                          }));
                        }}
                    />
                    {!editingId && autoSortOrder ? (
                      <small className="sort-order-note">
                        Tự động lấy số tiếp theo từ toàn bộ bài viết hiện có.
                      </small>
                    ) : null}
                  </label>
                  <label className="checkbox-row">
                    <input
                      type="checkbox"
                      checked={adminForm.published}
                      onChange={(event) =>
                        setAdminForm((current) => ({
                          ...current,
                          published: event.target.checked,
                        }))
                      }
                    />
                    <span>Hiển thị trên web thường</span>
                  </label>
                  <div className="form-actions content-composer-actions">
                    <button type="button" className="ghost-button" onClick={closeContentComposer} disabled={loading}>Hủy</button>
                    <button type="submit" className="content-save-button" disabled={loading}>
                      {loading ? 'Đang lưu...' : editingId ? 'Lưu thay đổi' : 'Đăng bài viết'}
                    </button>
                  </div>
                    </div>
                </form>
                  </div>,
                  document.body,
                ) : null}

                <section className="content-list panel">
                  <p className="panel-label">Bài viết</p>
                  <p className="panel-note">
                    Bài chưa xuất bản sẽ chỉ hiển thị trong khu quản trị, không lên
                    web thường.
                  </p>
                  <div className="content-items">
                    {contents.map((item) => (
                      <article
                        key={item.id}
                        className="content-item content-item-clickable"
                        role="button"
                        tabIndex={0}
                        onClick={() => openArticle(item)}
                        onKeyDown={(event) => {
                          if (event.key === 'Enter' || event.key === ' ') {
                            event.preventDefault();
                            openArticle(item);
                          }
                        }}
                      >
                        <div>
                          <p className="content-meta">
                            {item.page} / {item.key} / #{item.sortOrder}{' '}
                            {item.published ? '• published' : '• hidden'}
                          </p>
                          <h3>{item.title}</h3>
                          <p>{stripHtml(item.body)}</p>
                          <span className="content-open-hint">Xem toàn bộ nội dung →</span>
                        </div>
                        <div className="content-actions">
                          <button type="button" onClick={(event) => { event.stopPropagation(); editContent(item); }}>
                            Sửa
                          </button>
                          <button
                            type="button"
                            className="ghost-button"
                            onClick={(event) => { event.stopPropagation(); void deleteContent(item.id); }}
                          >
                            Xóa
                          </button>
                        </div>
                      </article>
                    ))}
                  </div>
                </section>
              </>
            ) : null}

            {adminAccountPickerOpen ? createPortal(
              <div className="article-modal-backdrop admin-picker-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !loading) setAdminAccountPickerOpen(false); }}>
                <section className="article-modal admin-account-picker" role="dialog" aria-modal="true" aria-labelledby="admin-picker-title">
                  <header className="admin-picker-head"><div><p className="panel-label">Phân quyền</p><h2 id="admin-picker-title">Thêm tài khoản admin</h2><p>Chọn một nhân viên hiện có để cấp quyền quản trị.</p></div><button type="button" className="request-modal-close" onClick={() => setAdminAccountPickerOpen(false)}>×</button></header>
                  <div className="admin-picker-body">
                    <div className="search-box"><input autoFocus value={adminAccountQuery} onChange={(event) => setAdminAccountQuery(event.target.value)} placeholder="Tìm theo tên, mã nhân viên hoặc phòng ban..." /></div>
                    <div className="admin-picker-list">
                      {accounts.filter((account) => account.savedAccountType === 'EMPLOYEE' && account.active && `${account.fullName} ${account.employeeCode} ${account.department}`.toLocaleLowerCase('vi').includes(adminAccountQuery.trim().toLocaleLowerCase('vi'))).map((account) => (
                        <article key={account.id} className="admin-picker-item"><div className="employee-avatar">{(account.fullName || '?').split(' ').slice(-2).map((part) => part[0]).join('').toUpperCase()}</div><div><strong>{account.fullName}</strong><p>{account.employeeCode} · {account.department || 'Chưa cập nhật phòng ban'}</p></div><button type="button" disabled={loading} onClick={() => void promoteAccountToAdmin(account)}>{loading ? 'Đang thêm...' : 'Chọn làm Admin'}</button></article>
                      ))}
                      {!accounts.some((account) => account.savedAccountType === 'EMPLOYEE' && account.active && `${account.fullName} ${account.employeeCode} ${account.department}`.toLocaleLowerCase('vi').includes(adminAccountQuery.trim().toLocaleLowerCase('vi'))) ? <div className="access-empty-state"><p>Không tìm thấy nhân viên phù hợp.</p></div> : null}
                    </div>
                  </div>
                </section>
              </div>, document.body
            ) : null}

          </section>
        </section>
      ) : null}

      {!isAdminRoute ? (
        <section className="account-privacy-panel panel">
          <div>
            <p className="panel-label">Quyền riêng tư và tài khoản</p>
            <h2>Kiểm soát dữ liệu cá nhân</h2>
            <p className="panel-note">Xem chính sách dữ liệu, nhận hỗ trợ hoặc yêu cầu xóa vĩnh viễn tài khoản và hồ sơ cá nhân.</p>
          </div>
          <div className="account-privacy-actions">
            <a className="ghost-button" href="/privacy-policy">Chính sách quyền riêng tư</a>
            <a className="ghost-button" href="/support">Hỗ trợ</a>
            <button type="button" className="danger-button" onClick={() => setDeleteAccountOpen(true)}>Xóa tài khoản</button>
          </div>
        </section>
      ) : null}

      {deleteAccountOpen && !isAdminRoute ? (
        <div className="dialog-backdrop" role="presentation" onMouseDown={() => setDeleteAccountOpen(false)}>
          <section className="delete-account-dialog" role="dialog" aria-modal="true" aria-labelledby="delete-account-title" onMouseDown={(event) => event.stopPropagation()}>
            <p className="panel-label">Hành động không thể hoàn tác</p>
            <h2 id="delete-account-title">Xóa tài khoản vĩnh viễn</h2>
            <p>Toàn bộ hồ sơ cá nhân gồm tên, Gmail, số điện thoại và mã nhân viên sẽ bị xóa khỏi hệ thống.</p>
            <label>
              <span>Mật khẩu hiện tại</span>
              <input type="password" autoComplete="current-password" value={deleteAccountForm.password} onChange={(event) => setDeleteAccountForm((current) => ({ ...current, password: event.target.value }))} />
            </label>
            <label>
              <span>Nhập “XOA TAI KHOAN” để xác nhận</span>
              <input value={deleteAccountForm.confirmation} onChange={(event) => setDeleteAccountForm((current) => ({ ...current, confirmation: event.target.value }))} />
            </label>
            {error ? <p className="error">{error}</p> : null}
            <div className="dialog-actions">
              <button type="button" className="ghost-button" onClick={() => setDeleteAccountOpen(false)}>Hủy</button>
              <button type="button" className="danger-button" disabled={loading || !deleteAccountForm.password || deleteAccountForm.confirmation.trim().toUpperCase() !== 'XOA TAI KHOAN'} onClick={() => void deleteMyAccount()}>{loading ? 'Đang xóa...' : 'Xóa vĩnh viễn'}</button>
            </div>
          </section>
        </div>
      ) : null}

      <section className="hint">
        {isAdminRoute
          ? 'Khu quản trị này dùng để thêm, sửa, xóa nội dung hiển thị cho web thường.'
          : 'Dữ liệu này đang được lấy từ backend thật qua JWT + Prisma.'}
      </section>
      <PublicFooter />
    </main>
  );
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <AppErrorBoundary>
      <App />
    </AppErrorBoundary>
  </React.StrictMode>,
);


