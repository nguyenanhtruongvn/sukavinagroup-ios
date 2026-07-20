import { Body, Controller, Delete, Get, Param, Patch, Post, Req, UseGuards } from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { EmployeesService } from './employees.service';

@UseGuards(JwtAuthGuard)
@Controller('admin/employees')
export class EmployeesController {
  constructor(private readonly employeesService: EmployeesService) {}

  @Get()
  list(@Req() req: { user: { employeeCode?: string; role?: string } }) {
    return this.employeesService.list(req.user);
  }

  @Post()
  create(
    @Req() req: { user: { employeeCode?: string; role?: string } },
    @Body()
    body: {
      employeeCode: string;
      fullName: string;
      jobTitle: string;
      department: string;
      managerEmployeeCode?: string | null;
      hireDate?: string | null;
      contractType?: string | null;
      phoneNumber?: string | null;
      gmailEmail?: string | null;
      password?: string | null;
      authProvider: string;
      remainingLeaveDays?: number;
      attendanceStatus?: string;
      payrollStatus?: string;
      active?: boolean;
    },
  ) {
    return this.employeesService.create(req.user, body);
  }

  @Patch(':id')
  update(
    @Req() req: { user: { employeeCode?: string; role?: string } },
    @Param('id') id: string,
    @Body()
    body: Partial<{
      employeeCode: string;
      fullName: string;
      jobTitle: string;
      department: string;
      managerEmployeeCode: string | null;
      hireDate: string | null;
      contractType: string | null;
      phoneNumber: string | null;
      gmailEmail: string | null;
      password: string | null;
      authProvider: string;
      remainingLeaveDays: number;
      attendanceStatus: string;
      payrollStatus: string;
      active: boolean;
    }>,
  ) {
    return this.employeesService.update(req.user, id, body);
  }

  @Delete(':id')
  remove(
    @Req() req: { user: { employeeCode?: string; role?: string } },
    @Param('id') id: string,
  ) {
    return this.employeesService.remove(req.user, id);
  }
}
