import * as ExcelJS from 'exceljs';
import { isMealOrderingOpen, parseWeeklyMenuWorkbook } from './weekly-menu.service';

describe('parseWeeklyMenuWorkbook', () => {
  it('maps the weekly Excel template into lunch and overtime meals', async () => {
    const workbook = new ExcelJS.Workbook();
    const sheet = workbook.addWorksheet('Thực đơn');
    ['Nội dung', 'Nội dung', 'Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7', 'Chủ Nhật']
      .forEach((value, index) => { sheet.getCell(1, index + 1).value = value; });
    sheet.getCell('C2').value = 'Bò kho';
    sheet.getCell('C3').value = 'Thịt ram';
    sheet.getCell('C4').value = 'Trứng';
    sheet.getCell('C5').value = 'Cải xào';
    sheet.getCell('C6').value = 'Canh bí';
    sheet.getCell('C8').value = 'Đậu hũ';
    sheet.getCell('C9').value = 'Rau luộc';
    sheet.getCell('C10').value = 'Bún mọc';

    const buffer = Buffer.from(await workbook.xlsx.writeBuffer());
    const result = await parseWeeklyMenuWorkbook(buffer);

    expect(result.days).toHaveLength(7);
    expect(result.days[0]).toMatchObject({
      dayName: 'Thứ 2',
      featured: 'Bò kho',
      savoryMain: 'Thịt ram',
      vegetarianMain: 'Đậu hũ',
      overtime: 'Bún mọc',
    });
  });
});

describe('isMealOrderingOpen', () => {
  afterEach(() => {
    delete process.env.MEAL_ORDERING_LOCK_ENABLED;
  });

  it('keeps ordering open when the temporary lock is disabled', () => {
    expect(isMealOrderingOpen(new Date('2026-07-28T02:00:00.000Z'))).toBe(true);
  });

  it('allows ordering before 09:00 in Vietnam', () => {
    process.env.MEAL_ORDERING_LOCK_ENABLED = 'true';
    expect(isMealOrderingOpen(new Date('2026-07-28T01:59:59.000Z'))).toBe(true);
  });

  it('closes ordering from 09:00 in Vietnam', () => {
    process.env.MEAL_ORDERING_LOCK_ENABLED = 'true';
    expect(isMealOrderingOpen(new Date('2026-07-28T02:00:00.000Z'))).toBe(false);
  });
});
