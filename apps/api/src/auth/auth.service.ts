import {
  BadRequestException,
  ConflictException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { PrismaService } from '../prisma/prisma.service';
import { compare, hash } from 'bcryptjs';
import { randomInt } from 'crypto';
import { RegistrationEventsService } from './registration-events.service';
import { MailService } from './mail.service';

@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwtService: JwtService,
    private readonly registrationEvents: RegistrationEventsService,
    private readonly mailService: MailService,
  ) {}

  async login(loginId: string, password: string) {
    const normalized = loginId.trim();
    const user = await this.prisma.employee.findFirst({
      where: {
        OR: [
          { employeeCode: normalized },
          { phoneNumber: normalized },
          { gmailEmail: normalized },
          { employeeCode: normalized.toLowerCase() },
        ],
      },
    });

    if (!user) {
      throw new UnauthorizedException('Invalid credentials');
    }

    if (!user.gmailVerified) {
      throw new UnauthorizedException('Tài khoản chưa xác minh Gmail');
    }

    if (!user.active) {
      throw new UnauthorizedException(
        'Tài khoản đang chờ quản trị viên xác nhận',
      );
    }

    const ok = await compare(password, user.passwordHash);
    if (!ok) {
      throw new UnauthorizedException('Invalid credentials');
    }

    const payload = {
      sub: user.id,
      employeeCode: user.employeeCode,
      role: user.role,
      accountType: user.accountType,
      permissions: user.permissions,
    };
    return {
      accessToken: await this.jwtService.signAsync(payload),
      user: {
        employeeCode: user.employeeCode,
        name: user.fullName,
        role: user.role,
        accountType: user.accountType,
        permissions: user.permissions,
        protected: user.protected,
      },
    };
  }

  async register(data: {
    employeeCode: string;
    fullName: string;
    phoneNumber?: string;
    gmailEmail?: string;
    password: string;
  }) {
    const employeeCode = data.employeeCode.trim();
    const fullName = data.fullName.trim();
    const phoneNumber = data.phoneNumber?.trim() || null;
    const gmailEmail = data.gmailEmail?.trim().toLowerCase() || null;
    if (
      !employeeCode ||
      !fullName ||
      data.password.length < 6 ||
      !gmailEmail ||
      !/^[^\s@]+@gmail\.com$/i.test(gmailEmail)
    ) {
      throw new BadRequestException('Thông tin đăng ký chưa hợp lệ');
    }

    const duplicate = await this.prisma.employee.findFirst({
      where: {
        OR: [
          { employeeCode },
          ...(phoneNumber ? [{ phoneNumber }] : []),
          ...(gmailEmail ? [{ gmailEmail }] : []),
        ],
      },
    });
    if (
      duplicate &&
      (duplicate.gmailVerified ||
        duplicate.employeeCode !== employeeCode ||
        duplicate.gmailEmail !== gmailEmail)
    ) {
      throw new ConflictException(
        'Mã nhân viên, số điện thoại hoặc Gmail đã tồn tại',
      );
    }

    const verificationCode = String(randomInt(100000, 1000000));
    const verificationData = {
      emailVerificationCode: await hash(verificationCode, 10),
      emailVerificationExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
      gmailVerified: false,
      active: false,
    };

    const user = duplicate
      ? await this.prisma.employee.update({
          where: { id: duplicate.id },
          data: {
            fullName,
            phoneNumber,
            passwordHash: await hash(data.password, 10),
            ...verificationData,
          },
        })
      : await this.prisma.employee.create({
          data: {
            employeeCode,
            fullName,
            phoneNumber,
            gmailEmail,
            passwordHash: await hash(data.password, 10),
            authProvider: 'phone_password',
            jobTitle: 'Nhân viên',
            department: 'Chưa cập nhật',
            role: 'Nhân viên',
            accountType: 'EMPLOYEE',
            permissions: [],
            protected: false,
            ...verificationData,
          },
        });
    await this.mailService.sendVerificationCode(gmailEmail, verificationCode);
    return {
      id: user.id,
      employeeCode: user.employeeCode,
      message: 'Mã xác minh đã được gửi tới Gmail.',
      requiresVerification: true,
    };
  }

  async verifyEmail(data: {
    employeeCode: string;
    gmailEmail: string;
    code: string;
  }) {
    const employeeCode = data.employeeCode.trim();
    const gmailEmail = data.gmailEmail.trim().toLowerCase();
    const user = await this.prisma.employee.findFirst({
      where: { employeeCode, gmailEmail },
    });
    if (
      !user ||
      user.gmailVerified ||
      !user.emailVerificationCode ||
      !user.emailVerificationExpiresAt
    ) {
      throw new BadRequestException('Yêu cầu xác minh không hợp lệ');
    }
    if (user.emailVerificationExpiresAt.getTime() < Date.now()) {
      throw new BadRequestException('Mã xác minh đã hết hạn');
    }
    if (!(await compare(data.code.trim(), user.emailVerificationCode))) {
      throw new BadRequestException('Mã xác minh không đúng');
    }

    await this.prisma.employee.update({
      where: { id: user.id },
      data: {
        gmailVerified: true,
        emailVerificationCode: null,
        emailVerificationExpiresAt: null,
      },
    });
    this.registrationEvents.notify();
    return {
      message: 'Xác minh Gmail thành công. Tài khoản đang chờ admin duyệt.',
    };
  }

  async resendVerification(data: { employeeCode: string; gmailEmail: string }) {
    const employeeCode = data.employeeCode.trim();
    const gmailEmail = data.gmailEmail.trim().toLowerCase();
    const user = await this.prisma.employee.findFirst({
      where: { employeeCode, gmailEmail, gmailVerified: false },
    });
    if (!user) throw new BadRequestException('Không tìm thấy yêu cầu xác minh');

    const verificationCode = String(randomInt(100000, 1000000));
    await this.prisma.employee.update({
      where: { id: user.id },
      data: {
        emailVerificationCode: await hash(verificationCode, 10),
        emailVerificationExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
      },
    });
    await this.mailService.sendVerificationCode(gmailEmail, verificationCode);
    return { message: 'Đã gửi lại mã xác minh.' };
  }

  async profile(id: string) {
    const user = await this.prisma.employee.findUnique({ where: { id } });
    if (!user || !user.active) throw new UnauthorizedException('Account disabled');
    return {
      id: user.id,
      employeeCode: user.employeeCode,
      name: user.fullName,
      role: user.role,
      accountType: user.accountType,
      permissions: user.permissions,
      protected: user.protected,
      email: user.gmailEmail,
      passwordChangedAt: user.passwordChangedAt,
    };
  }

  async requestPasswordChange(id: string) {
    const user = await this.prisma.employee.findUnique({ where: { id } });
    if (!user || !user.active) throw new UnauthorizedException('Tài khoản không tồn tại');
    if (!user.gmailEmail) {
      throw new BadRequestException('Tài khoản chưa có email. Vui lòng liên hệ Nhân sự để cập nhật email.');
    }
    this.ensurePasswordChangeAllowed(user.passwordChangedAt);
    if (user.passwordChangeRequestedAt && Date.now() - user.passwordChangeRequestedAt.getTime() < 60_000) {
      throw new BadRequestException('Vui lòng chờ 60 giây trước khi yêu cầu mã OTP mới.');
    }
    const code = String(randomInt(100000, 1000000));
    await this.prisma.employee.update({
      where: { id },
      data: {
        passwordChangeCode: await hash(code, 10),
        passwordChangeExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
        passwordChangeRequestedAt: new Date(),
      },
    });
    await this.mailService.sendPasswordChangeCode(user.gmailEmail, code);
    return {
      message: `Mã OTP đã được gửi tới ${user.gmailEmail}.`,
      email: user.gmailEmail,
      expiresInMinutes: 10,
    };
  }

  async confirmPasswordChange(id: string, code: string, newPassword: string) {
    if (!newPassword || newPassword.length < 6) {
      throw new BadRequestException('Mật khẩu mới phải có ít nhất 6 ký tự.');
    }
    const user = await this.prisma.employee.findUnique({ where: { id } });
    if (!user || !user.active) throw new UnauthorizedException('Tài khoản không tồn tại');
    this.ensurePasswordChangeAllowed(user.passwordChangedAt);
    if (!user.passwordChangeCode || !user.passwordChangeExpiresAt) {
      throw new BadRequestException('Vui lòng yêu cầu mã OTP mới.');
    }
    if (user.passwordChangeExpiresAt.getTime() < Date.now()) {
      throw new BadRequestException('Mã OTP đã hết hạn. Vui lòng yêu cầu mã mới.');
    }
    if (!(await compare(code.trim(), user.passwordChangeCode))) {
      throw new BadRequestException('Mã OTP không chính xác.');
    }
    await this.prisma.employee.update({
      where: { id },
      data: {
        passwordHash: await hash(newPassword, 10),
        passwordChangedAt: new Date(),
        passwordChangeCode: null,
        passwordChangeExpiresAt: null,
        passwordChangeRequestedAt: null,
      },
    });
    return { message: 'Đổi mật khẩu thành công.' };
  }

  private ensurePasswordChangeAllowed(changedAt: Date | null) {
    if (!changedAt) return;
    const vietnamOffset = 7 * 60 * 60 * 1000;
    const now = new Date(Date.now() + vietnamOffset);
    const changed = new Date(changedAt.getTime() + vietnamOffset);
    if (changed.getUTCFullYear() === now.getUTCFullYear() && changed.getUTCMonth() === now.getUTCMonth()) {
      throw new BadRequestException('Bạn chỉ được đổi mật khẩu một lần mỗi tháng.');
    }
  }

  async deleteMyAccount(id: string, password: string, confirmation: string) {
    const user = await this.prisma.employee.findUnique({ where: { id } });
    if (!user) throw new UnauthorizedException('Tài khoản không tồn tại');
    if (user.protected || user.accountType === 'SUPER_ADMIN') {
      throw new BadRequestException('Tài khoản quản trị tổng không thể tự xóa');
    }
    if (confirmation.trim().toUpperCase() !== 'XOA TAI KHOAN') {
      throw new BadRequestException('Cụm từ xác nhận chưa chính xác');
    }
    if (!user.passwordHash || !(await compare(password, user.passwordHash))) {
      throw new UnauthorizedException('Mật khẩu không chính xác');
    }

    await this.prisma.employee.delete({ where: { id } });
    return { message: 'Tài khoản và dữ liệu cá nhân đã được xóa vĩnh viễn.' };
  }
}
