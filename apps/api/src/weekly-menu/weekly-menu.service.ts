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

@Injectable()
export class WeeklyMenuService {
  constructor(private readonly prisma: PrismaService) {}

  async current(user: AuthUser) {
    assertPermission(user, 'content.manage');
    return this.prisma.weeklyMenu.findUnique({ where: { weekStart: currentWeekStart() } });
  }

  async import(user: AuthUser, file?: Express.Multer.File) {
    assertPermission(user, 'content.manage');
    if (!file) throw new BadRequestException('Vui lòng chọn file Excel.');
    if (!file.originalname.toLocaleLowerCase('vi').endsWith('.xlsx')) {
      throw new BadRequestException('Chỉ hỗ trợ file Excel định dạng .xlsx.');
    }

    const data = await parseWeeklyMenuWorkbook(file.buffer);
    const weekStart = currentWeekStart();
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
}
