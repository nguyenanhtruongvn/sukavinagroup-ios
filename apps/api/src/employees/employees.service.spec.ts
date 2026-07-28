import * as ExcelJS from 'exceljs';
import { parseEmployeeWorkbook } from './employees.service';

describe('parseEmployeeWorkbook', () => {
  it('reads the employee import template', async () => {
    const workbook = new ExcelJS.Workbook();
    const sheet = workbook.addWorksheet('Nhân viên');
    [
      'MSNV',
      'Họ và tên',
      'Phòng ban',
      'MSNV quản lý',
      'Chức danh',
      'Ngày vào làm',
      'Loại hợp đồng',
      'Email',
      'Số điện thoại',
    ].forEach((value, index) => {
      sheet.getCell(1, index + 1).value = value;
    });
    [
      'NV001',
      'Nguyễn Văn A',
      'Kỹ thuật',
      'QL001',
      'Nhân viên',
      '28/07/2026',
      'Chính thức',
      'nva@sukavina.com',
      '0900000001',
    ].forEach((value, index) => {
      sheet.getCell(2, index + 1).value = value;
    });

    const result = await parseEmployeeWorkbook(
      Buffer.from(await workbook.xlsx.writeBuffer()),
    );

    expect(result).toHaveLength(1);
    expect(result[0]).toMatchObject({
      employeeCode: 'NV001',
      fullName: 'Nguyễn Văn A',
      managerEmployeeCode: 'QL001',
      gmailEmail: 'nva@sukavina.com',
      phoneNumber: '0900000001',
    });
    expect(result[0].hireDate?.toISOString()).toBe('2026-07-28T00:00:00.000Z');
  });
});
