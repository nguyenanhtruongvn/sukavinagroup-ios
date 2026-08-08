import { BadRequestException, ForbiddenException, Injectable } from '@nestjs/common';
import * as ExcelJS from 'exceljs';
import { createHmac, randomBytes, timingSafeEqual } from 'crypto';
import { AuthUser, assertPermission } from '../auth/permissions';
import { getJwtSecret } from '../auth/jwt-secret';
import { PrismaService } from '../prisma/prisma.service';
import { ContentEventsService } from '../dashboard/content-events.service';

const dayNames = ['Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7', 'Chủ nhật'];

export type WeeklyMenuDay = {
  dayIndex: number;
  dayName: string;
  featured: string;
  savoryMain: string;
  savorySide: string;
  vegetable: string;
  soup: string;
  vegetarianMain: string;
  vegetarianSide: string;
  overtime: string;
};

export type WeeklyMenuData = {
  days: WeeklyMenuDay[];
};

const cellText = (sheet: ExcelJS.Worksheet, row: number, column: number) =>
  sheet.getCell(row, column).text.trim();

export async function parseWeeklyMenuWorkbook(buffer: Buffer): Promise<WeeklyMenuData> {
  const workbook = new ExcelJS.Workbook();
  try {
    await workbook.xlsx.load(buffer as unknown as ExcelJS.Buffer);
  } catch {
    throw new BadRequestException('File Excel không hợp lệ hoặc đã bị hỏng.');
  }

  const sheet = workbook.worksheets[0];
  if (!sheet) throw new BadRequestException('File Excel không có trang dữ liệu.');

  const headers = dayNames.map((_, index) => cellText(sheet, 1, index + 3).toLocaleLowerCase('vi'));
  if (!headers[0].includes('thứ 2') || !headers[6].includes('chủ nhật')) {
    throw new BadRequestException(
      'File chưa đúng mẫu: hàng đầu phải gồm Thứ 2 đến Chủ nhật tại các cột C–I.',
    );
  }

  const days = dayNames.map((dayName, dayIndex): WeeklyMenuDay => {
    const column = dayIndex + 3;
    return {
      dayIndex,
      dayName,
      featured: cellText(sheet, 2, column),
      savoryMain: cellText(sheet, 3, column),
      savorySide: cellText(sheet, 4, column),
      vegetable: cellText(sheet, 5, column),
      soup: cellText(sheet, 6, column),
      vegetarianMain: cellText(sheet, 8, column),
      vegetarianSide: cellText(sheet, 9, column),
      overtime: cellText(sheet, 10, column),
    };
  });

  if (!days.some((day) => Object.values(day).some((value) => typeof value === 'string' && value))) {
    throw new BadRequestException('File Excel chưa có món ăn để import.');
  }
  return { days };
}

function currentWeekStart() {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Ho_Chi_Minh',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const today = new Date(Date.UTC(Number(value.year), Number(value.month) - 1, Number(value.day)));
  const offset = (today.getUTCDay() + 6) % 7;
  today.setUTCDate(today.getUTCDate() - offset);
  return today;
}

function selectedWeekStart(week?: string) {
  if (week !== undefined && week !== 'current' && week !== 'next') {
    throw new BadRequestException('Chỉ hỗ trợ thực đơn tuần này hoặc tuần sau.');
  }
  const weekStart = currentWeekStart();
  if (week === 'next') weekStart.setUTCDate(weekStart.getUTCDate() + 7);
  return weekStart;
}

function todayInVietnam() {
  const value = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Ho_Chi_Minh',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
  return new Date(`${value}T00:00:00.000Z`);
}

export function isMealOrderingOpen(now = new Date()) {
  // Khóa giờ đặt món đang tạm tắt. Có thể bật lại mà không sửa code bằng biến môi trường.
  const orderingLockEnabled =
    process.env.MEAL_ORDERING_LOCK_ENABLED?.trim().toLowerCase() === 'true';
  if (!orderingLockEnabled) return true;

  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Ho_Chi_Minh',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(now);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return Number(values.hour) < 9;
}

@Injectable()
export class WeeklyMenuService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly events: ContentEventsService,
  ) {}

  async current(user: AuthUser, week?: string) {
    assertPermission(user, 'menu.manage');
    return this.prisma.weeklyMenu.findUnique({ where: { weekStart: selectedWeekStart(week) } });
  }

  private async removeExpiredSelections() {
    await this.prisma.mealSelection.deleteMany({
      where: { mealDate: { lt: todayInVietnam() } },
    });
  }

  private createMealQrToken(selection: { id: string; employeeId: string; mealDate: Date }, expiresAt: Date) {
    const payload = Buffer.from(JSON.stringify({
      selectionId: selection.id,
      employeeId: selection.employeeId,
      mealDate: selection.mealDate.toISOString().slice(0, 10),
      expiresAt: expiresAt.getTime(),
      nonce: randomBytes(16).toString('base64url'),
    })).toString('base64url');
    const signature = createHmac('sha256', getJwtSecret()).update(payload).digest('base64url');
    return `sukavina-meal:${payload}.${signature}`;
  }

  private verifyMealQrToken(value?: string) {
    if (!value?.startsWith('sukavina-meal:')) {
      throw new BadRequestException('Mã QR suất ăn không hợp lệ.');
    }
    const [payload, signature] = value.slice('sukavina-meal:'.length).split('.');
    if (!payload || !signature) throw new BadRequestException('Mã QR suất ăn không hợp lệ.');
    const expected = createHmac('sha256', getJwtSecret()).update(payload).digest();
    const actual = Buffer.from(signature, 'base64url');
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
      throw new BadRequestException('Mã QR suất ăn không hợp lệ hoặc đã bị thay đổi.');
    }
    try {
      const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as {
        selectionId: string;
        employeeId: string;
        mealDate: string;
        expiresAt: number;
        nonce: string;
      };
      if (!Number.isFinite(decoded.expiresAt) || decoded.expiresAt <= Date.now()) {
        throw new BadRequestException('Mã QR đã hết hạn. Vui lòng lấy mã mới.');
      }
      return decoded;
    } catch (error) {
      if (error instanceof BadRequestException) throw error;
      throw new BadRequestException('Mã QR suất ăn không hợp lệ.');
    }
  }

  async selections(user: AuthUser, _week?: string) {
    assertPermission(user, 'menu.manage');
    await this.removeExpiredSelections();
    const start = todayInVietnam();
    const end = new Date(start);
    end.setUTCDate(end.getUTCDate() + 1);
    return this.prisma.mealSelection.findMany({
      where: { mealDate: { gte: start, lt: end } },
      select: {
        id: true,
        mealDate: true,
        choice: true,
        receivedAt: true,
        createdAt: true,
        employee: {
          select: {
            employeeCode: true,
            fullName: true,
            department: true,
          },
        },
      },
      orderBy: [{ mealDate: 'desc' }, { createdAt: 'desc' }],
    });
  }

  async today(user: AuthUser) {
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    await this.removeExpiredSelections();
    const mealDate = todayInVietnam();
    const weekStart = new Date(mealDate);
    weekStart.setUTCDate(weekStart.getUTCDate() - ((weekStart.getUTCDay() + 6) % 7));
    const [menu, selection] = await Promise.all([
      this.prisma.weeklyMenu.findUnique({ where: { weekStart } }),
      this.prisma.mealSelection.findUnique({
        where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
      }),
    ]);
    const dayIndex = (mealDate.getUTCDay() + 6) % 7;
    const data = menu?.data as WeeklyMenuData | undefined;
    return {
      date: mealDate.toISOString().slice(0, 10),
      day: data?.days?.find((item) => item.dayIndex === dayIndex) ?? {
        dayIndex,
        dayName: dayNames[dayIndex],
        featured: '',
        savoryMain: '',
        savorySide: '',
        vegetable: '',
        soup: '',
        vegetarianMain: '',
        vegetarianSide: '',
        overtime: '',
      },
      selection: selection?.choice ?? null,
      receivedAt: selection?.receivedAt?.toISOString() ?? null,
      orderingOpen: isMealOrderingOpen(),
      orderingCutoff: '09:00',
    };
  }

  async issueMealQr(user: AuthUser) {
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    if (user.accountType === 'CANTEEN') {
      throw new ForbiddenException('Tài khoản nhà ăn không thể tạo mã nhận món.');
    }
    const mealDate = todayInVietnam();
    const selection = await this.prisma.mealSelection.findUnique({
      where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
    });
    if (!selection) throw new BadRequestException('Bạn chưa lựa chọn món ăn hôm nay.');
    if (selection.receivedAt) throw new BadRequestException('Suất ăn này đã được xác nhận.');
    const expiresAt = new Date(Date.now() + 30_000);
    return {
      token: this.createMealQrToken(selection, expiresAt),
      expiresAt: expiresAt.toISOString(),
      expiresInSeconds: 30,
    };
  }

  async selectMeal(user: AuthUser, choice?: string) {
    if (!isMealOrderingOpen()) {
      throw new BadRequestException('Đã hết thời gian đặt món. Vui lòng đặt món trước 09:00.');
    }
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    if (choice !== 'water' && choice !== 'vegetarian') {
      throw new BadRequestException('Vui lòng chọn Món nước hoặc Món chay.');
    }
    const mealDate = todayInVietnam();
    const current = await this.prisma.mealSelection.findUnique({
      where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
    });
    if (current?.receivedAt) {
      throw new BadRequestException('Món ăn đã được xác nhận nhận nên không thể thay đổi.');
    }
    await this.prisma.mealSelection.upsert({
      where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
      update: { choice, receivedAt: null },
      create: { employeeId: user.sub, mealDate, choice },
    });
    this.events.notify('meal_changed');
    return this.today(user);
  }

  async receiveMealSelection(user: AuthUser) {
    if (user.accountType !== 'CANTEEN' && user.accountType !== 'DEMO') {
      throw new ForbiddenException('Suất ăn chỉ được xác nhận bằng mã QR tại nhà ăn.');
    }
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    const mealDate = todayInVietnam();
    const selection = await this.prisma.mealSelection.findUnique({
      where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
    });
    if (!selection) {
      throw new BadRequestException('Bạn chưa lựa chọn món ăn hôm nay.');
    }
    await this.prisma.mealSelection.update({
      where: { id: selection.id },
      data: { receivedAt: new Date() },
    });
    this.events.notify('meal_changed');
    return this.today(user);
  }

  async scanMealQr(user: AuthUser, token?: string) {
    if (user.accountType !== 'CANTEEN' && user.accountType !== 'DEMO') {
      throw new ForbiddenException('Chỉ tài khoản nhà ăn được phép quét mã suất ăn.');
    }
    const payload = this.verifyMealQrToken(token);
    if (payload.mealDate !== todayInVietnam().toISOString().slice(0, 10)) {
      throw new BadRequestException('Mã QR này không thuộc ngày hôm nay.');
    }
    const selection = await this.prisma.mealSelection.findUnique({
      where: { id: payload.selectionId },
      include: { employee: { select: { employeeCode: true, fullName: true, department: true } } },
    });
    if (!selection || selection.employeeId !== payload.employeeId ||
        selection.mealDate.toISOString().slice(0, 10) !== payload.mealDate) {
      throw new BadRequestException('Không tìm thấy thông tin đặt món tương ứng.');
    }
    if (selection.receivedAt) {
      return {
        valid: true,
        alreadyReceived: true,
        employeeCode: selection.employee.employeeCode,
        fullName: selection.employee.fullName,
        department: selection.employee.department,
        choice: selection.choice,
        mealDate: payload.mealDate,
        receivedAt: selection.receivedAt.toISOString(),
      };
    }
    const updated = await this.prisma.mealSelection.update({
      where: { id: selection.id },
      data: { receivedAt: new Date() },
    });
    this.events.notify('meal_changed');
    return {
      valid: true,
      alreadyReceived: false,
      employeeCode: selection.employee.employeeCode,
      fullName: selection.employee.fullName,
      department: selection.employee.department,
      choice: selection.choice,
      mealDate: payload.mealDate,
      receivedAt: updated.receivedAt?.toISOString() ?? new Date().toISOString(),
    };
  }

  async cancelMealSelection(user: AuthUser) {
    if (!isMealOrderingOpen()) {
      throw new BadRequestException('Đã hết thời gian thay đổi món. Chỉ có thể hủy trước 09:00.');
    }
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    const mealDate = todayInVietnam();
    const selection = await this.prisma.mealSelection.findUnique({
      where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
    });
    if (selection?.receivedAt) {
      throw new BadRequestException('Món ăn đã được xác nhận nhận nên không thể hủy.');
    }
    await this.prisma.mealSelection.deleteMany({
      where: { employeeId: user.sub, mealDate },
    });
    this.events.notify('meal_changed');
    return this.today(user);
  }

  async import(user: AuthUser, file?: Express.Multer.File, week?: string) {
    assertPermission(user, 'menu.manage');
    if (!file) throw new BadRequestException('Vui lòng chọn file Excel.');
    if (!file.originalname.toLocaleLowerCase('vi').endsWith('.xlsx')) {
      throw new BadRequestException('Chỉ hỗ trợ file Excel định dạng .xlsx.');
    }

    const data = await parseWeeklyMenuWorkbook(file.buffer);
    const weekStart = selectedWeekStart(week);
    return this.prisma.weeklyMenu.upsert({
      where: { weekStart },
      update: {
        data,
        sourceName: file.originalname,
        importedBy: user.employeeCode,
      },
      create: {
        weekStart,
        data,
        sourceName: file.originalname,
        importedBy: user.employeeCode,
      },
    });
  }

  async update(user: AuthUser, data: WeeklyMenuData, week?: string) {
    assertPermission(user, 'menu.manage');
    if (!Array.isArray(data?.days) || data.days.length !== dayNames.length) {
      throw new BadRequestException('Thực đơn phải có đủ 7 ngày từ Thứ 2 đến Chủ nhật.');
    }

    const days = data.days.map((day, dayIndex): WeeklyMenuDay => ({
      dayIndex,
      dayName: dayNames[dayIndex],
      featured: String(day.featured ?? '').trim(),
      savoryMain: String(day.savoryMain ?? '').trim(),
      savorySide: String(day.savorySide ?? '').trim(),
      vegetable: String(day.vegetable ?? '').trim(),
      soup: String(day.soup ?? '').trim(),
      vegetarianMain: String(day.vegetarianMain ?? '').trim(),
      vegetarianSide: String(day.vegetarianSide ?? '').trim(),
      overtime: String(day.overtime ?? '').trim(),
    }));
    const weekStart = selectedWeekStart(week);
    return this.prisma.weeklyMenu.upsert({
      where: { weekStart },
      update: {
        data: { days },
        importedBy: user.employeeCode,
      },
      create: {
        weekStart,
        data: { days },
        sourceName: 'Chỉnh sửa thủ công',
        importedBy: user.employeeCode,
      },
    });
  }
}
