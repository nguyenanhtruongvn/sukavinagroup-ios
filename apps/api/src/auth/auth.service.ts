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
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';
import type {
  AuthenticationResponseJSON,
  RegistrationResponseJSON,
} from '@simplewebauthn/server';
import { RegistrationEventsService } from './registration-events.service';
import { MailService } from './mail.service';

@Injectable()
export class AuthService {
  private readonly passkeyRpId = process.env.PASSKEY_RP_ID ?? 'sukavinagroup.net';
  private readonly passkeyOrigin = process.env.PASSKEY_ORIGIN ?? 'https://sukavinagroup.net';
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

    return this.issueSession(user);
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
    const user = await this.prisma.employee.findUnique({
      where: { id },
      include: { _count: { select: { passkeys: true } } },
    });
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
      passkeyEnabled: user._count.passkeys > 0,
    };
  }

  async passkeyRegistrationOptions(employeeId: string) {
    const user = await this.prisma.employee.findUnique({
      where: { id: employeeId },
      include: { passkeys: true },
    });
    if (!user || !user.active) throw new UnauthorizedException('Tài khoản không tồn tại');
    const options = await generateRegistrationOptions({
      rpName: 'Sukavina',
      rpID: this.passkeyRpId,
      userID: Buffer.from(user.id, 'utf8'),
      userName: user.employeeCode,
      userDisplayName: user.fullName,
      attestationType: 'none',
      excludeCredentials: user.passkeys.map((credential) => ({
        id: credential.id,
        transports: credential.transports as AuthenticatorTransport[],
      })),
      authenticatorSelection: {
        residentKey: 'required',
        userVerification: 'required',
      },
    });
    const challengeToken = await this.jwtService.signAsync(
      { purpose: 'passkey-register', employeeId, challenge: options.challenge },
      { expiresIn: '5m' },
    );
    return { options, challengeToken };
  }

  async verifyPasskeyRegistration(
    employeeId: string,
    challengeToken: string,
    response: RegistrationResponseJSON,
  ) {
    const challenge = await this.verifyPasskeyChallenge(challengeToken, 'passkey-register', employeeId);
    const verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge,
      expectedOrigin: this.passkeyOrigin,
      expectedRPID: this.passkeyRpId,
      requireUserVerification: true,
    });
    if (!verification.verified || !verification.registrationInfo) {
      throw new BadRequestException('Không thể xác minh Passkey.');
    }
    const { credential, credentialDeviceType, credentialBackedUp } = verification.registrationInfo;
    await this.prisma.webAuthnCredential.upsert({
      where: { id: credential.id },
      create: {
        id: credential.id,
        employeeId,
        publicKey: Buffer.from(credential.publicKey),
        counter: BigInt(credential.counter),
        transports: response.response.transports ?? [],
        deviceType: credentialDeviceType,
        backedUp: credentialBackedUp,
      },
      update: {
        employeeId,
        publicKey: Buffer.from(credential.publicKey),
        counter: BigInt(credential.counter),
        transports: response.response.transports ?? [],
        deviceType: credentialDeviceType,
        backedUp: credentialBackedUp,
      },
    });
    return { message: 'Đã bật đăng nhập bằng sinh trắc học trên website.' };
  }

  async passkeyAuthenticationOptions() {
    const options = await generateAuthenticationOptions({
      rpID: this.passkeyRpId,
      userVerification: 'required',
      allowCredentials: [],
    });
    const challengeToken = await this.jwtService.signAsync(
      { purpose: 'passkey-login', challenge: options.challenge },
      { expiresIn: '5m' },
    );
    return { options, challengeToken };
  }

  async verifyPasskeyAuthentication(
    challengeToken: string,
    response: AuthenticationResponseJSON,
  ) {
    const challenge = await this.verifyPasskeyChallenge(challengeToken, 'passkey-login');
    const stored = await this.prisma.webAuthnCredential.findUnique({
      where: { id: response.id },
      include: { employee: true },
    });
    if (!stored || !stored.employee.active) throw new UnauthorizedException('Passkey không hợp lệ.');
    const verification = await verifyAuthenticationResponse({
      response,
      expectedChallenge: challenge,
      expectedOrigin: this.passkeyOrigin,
      expectedRPID: this.passkeyRpId,
      credential: {
        id: stored.id,
        publicKey: new Uint8Array(stored.publicKey),
        counter: Number(stored.counter),
        transports: stored.transports as AuthenticatorTransport[],
      },
      requireUserVerification: true,
    });
    if (!verification.verified) throw new UnauthorizedException('Không thể xác minh sinh trắc học.');
    await this.prisma.webAuthnCredential.update({
      where: { id: stored.id },
      data: { counter: BigInt(verification.authenticationInfo.newCounter) },
    });
    const user = stored.employee;
    return this.issueSession(user);
  }

  async refreshSession(refreshToken: string) {
    try {
      const payload = await this.jwtService.verifyAsync<{ sub: string; purpose?: string }>(refreshToken);
      if (payload.purpose !== 'refresh') throw new Error('Invalid token purpose');
      const user = await this.prisma.employee.findUnique({ where: { id: payload.sub } });
      if (!user || !user.active || !user.gmailVerified) throw new Error('Inactive account');
      return this.issueSession(user);
    } catch {
      throw new UnauthorizedException('Phiên đăng nhập đã hết hạn');
    }
  }

  async verifyWidgetToken(widgetToken: string) {
    try {
      const payload = await this.jwtService.verifyAsync<{ sub: string; purpose?: string }>(widgetToken);
      if (payload.purpose !== 'attendance-widget') throw new Error('Invalid token purpose');
      const user = await this.prisma.employee.findUnique({
        where: { id: payload.sub },
        select: { id: true, active: true },
      });
      if (!user?.active) throw new Error('Inactive account');
      return user.id;
    } catch {
      throw new UnauthorizedException('Widget token không hợp lệ');
    }
  }

  private async issueSession(user: {
    id: string;
    employeeCode: string;
    fullName: string;
    role: string;
    accountType: string;
    permissions: string[];
    protected: boolean;
  }) {
    const payload = {
      sub: user.id,
      employeeCode: user.employeeCode,
      role: user.role,
      accountType: user.accountType,
      permissions: user.permissions,
    };
    const [accessToken, refreshToken, widgetToken] = await Promise.all([
      this.jwtService.signAsync(payload, { expiresIn: '24h' }),
      this.jwtService.signAsync({ sub: user.id, purpose: 'refresh' }, { expiresIn: '180d' }),
      this.jwtService.signAsync({ sub: user.id, purpose: 'attendance-widget' }, { expiresIn: '180d' }),
    ]);
    return {
      accessToken,
      refreshToken,
      widgetToken,
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

  async removePasskeys(employeeId: string) {
    await this.prisma.webAuthnCredential.deleteMany({ where: { employeeId } });
    return { message: 'Đã tắt đăng nhập bằng sinh trắc học trên website.' };
  }

  private async verifyPasskeyChallenge(token: string, purpose: string, employeeId?: string) {
    try {
      const payload = await this.jwtService.verifyAsync<{
        purpose: string;
        employeeId?: string;
        challenge: string;
      }>(token);
      if (payload.purpose !== purpose || (employeeId && payload.employeeId !== employeeId)) throw new Error();
      return payload.challenge;
    } catch {
      throw new BadRequestException('Yêu cầu sinh trắc học đã hết hạn. Vui lòng thử lại.');
    }
  }

  async requestPasswordChange(id: string) {
    const user = await this.prisma.employee.findUnique({ where: { id } });
    if (!user || !user.active) throw new UnauthorizedException('Tài khoản không tồn tại');
    if (!user.gmailEmail) {
      throw new BadRequestException('Tài khoản chưa có email. Vui lòng liên hệ Nhân sự để cập nhật email.');
    }
    this.ensurePasswordChangeAllowed(user.passwordChangedAt, user.accountType);
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
    this.ensurePasswordChangeAllowed(user.passwordChangedAt, user.accountType);
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

  private ensurePasswordChangeAllowed(changedAt: Date | null, accountType: string) {
    if (accountType === 'ADMIN' || accountType === 'SUPER_ADMIN') return;
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
