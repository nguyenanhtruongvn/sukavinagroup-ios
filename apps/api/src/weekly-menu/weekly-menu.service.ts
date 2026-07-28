import { BadRequestException, Injectable } from '@nestjs/common';
import * as ExcelJS from 'exceljs';
import { AuthUser, assertPermission } from '../auth/permissions';
import { PrismaService } from '../prisma/prisma.service';

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

@Injectable()
export class WeeklyMenuService {
  constructor(private readonly prisma: PrismaService) {}

  async current(user: AuthUser, week?: string) {
    assertPermission(user, 'content.manage');
    return this.prisma.weeklyMenu.findUnique({ where: { weekStart: selectedWeekStart(week) } });
  }

  async today(user: AuthUser) {
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
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
    };
  }

  async selectMeal(user: AuthUser, choice?: string) {
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    if (choice !== 'water' && choice !== 'vegetarian') {
      throw new BadRequestException('Vui lòng chọn Món nước hoặc Món chay.');
    }
    const mealDate = todayInVietnam();
    await this.prisma.mealSelection.upsert({
      where: { employeeId_mealDate: { employeeId: user.sub, mealDate } },
      update: { choice },
      create: { employeeId: user.sub, mealDate, choice },
    });
    return this.today(user);
  }

  async cancelMealSelection(user: AuthUser) {
    if (!user.sub) throw new BadRequestException('Không xác định được tài khoản.');
    const mealDate = todayInVietnam();
    await this.prisma.mealSelection.deleteMany({
      where: { employeeId: user.sub, mealDate },
    });
    return this.today(user);
  }

  async import(user: AuthUser, file?: Express.Multer.File, week?: string) {
    assertPermission(user, 'content.manage');
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
    assertPermission(user, 'content.manage');
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
