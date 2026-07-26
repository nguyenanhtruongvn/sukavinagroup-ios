import {
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import * as nodemailer from 'nodemailer';
import { PrismaService } from '../prisma/prisma.service';

type MailKind = 'verification' | 'password_change' | 'account_approved';
type MailPayload = { code?: string; employeeCode?: string };

@Injectable()
export class MailService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailService.name);
  private readonly fromAddress = process.env.SMTP_FROM ?? process.env.SMTP_USER;
  private readonly transporter = nodemailer.createTransport({
    pool: true,
    maxConnections: 1,
    maxMessages: 50,
    host: process.env.SMTP_HOST ?? 'smtp.gmail.com',
    port: Number(process.env.SMTP_PORT ?? 465),
    secure: (process.env.SMTP_SECURE ?? 'true') === 'true',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS,
    },
  });
  private timer?: NodeJS.Timeout;
  private processing = false;

  constructor(private readonly prisma: PrismaService) {}

  async onModuleInit() {
    await this.releaseStaleJobs();
    this.timer = setInterval(() => void this.processNext(), 500);
    this.timer.unref();
    void this.processNext();
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
    this.transporter.close();
  }

  async sendVerificationCode(recipient: string, code: string) {
    await this.enqueue('verification', recipient, { code });
  }

  async sendPasswordChangeCode(recipient: string, code: string) {
    await this.enqueue('password_change', recipient, { code });
  }

  async sendAccountApproved(recipient: string, employeeCode: string) {
    await this.enqueue('account_approved', recipient, { employeeCode });
  }

  private async enqueue(
    kind: MailKind,
    recipient: string,
    payload: MailPayload,
  ) {
    await this.prisma.emailJob.create({
      data: {
        kind,
        recipient,
        payload: JSON.stringify(payload),
      },
    });
    void this.processNext();
  }

  private async processNext() {
    if (this.processing) return;
    this.processing = true;
    try {
      const job = await this.prisma.emailJob.findFirst({
        where: {
          status: 'pending',
          scheduledAt: { lte: new Date() },
        },
        orderBy: [{ scheduledAt: 'asc' }, { createdAt: 'asc' }],
      });
      if (!job) return;

      const claimed = await this.prisma.emailJob.updateMany({
        where: { id: job.id, status: 'pending' },
        data: { status: 'processing', lockedAt: new Date() },
      });
      if (claimed.count !== 1) return;

      try {
        await this.deliver(
          job.kind as MailKind,
          job.recipient,
          JSON.parse(job.payload),
        );
        await this.prisma.emailJob.delete({ where: { id: job.id } });
      } catch (error) {
        const attempts = job.attempts + 1;
        const failed = attempts >= 5;
        const delaySeconds = Math.min(300, 10 * 2 ** Math.max(0, attempts - 1));
        await this.prisma.emailJob.update({
          where: { id: job.id },
          data: {
            status: failed ? 'failed' : 'pending',
            attempts,
            lockedAt: null,
            scheduledAt: new Date(Date.now() + delaySeconds * 1000),
            lastError: this.errorMessage(error).slice(0, 500),
          },
        });
        this.logger.error(
          `Email job ${job.id} failed on attempt ${attempts}: ${this.errorMessage(error)}`,
        );
      }
    } finally {
      this.processing = false;
    }
  }

  private async releaseStaleJobs() {
    await Promise.all([
      this.prisma.emailJob.updateMany({
        where: {
          status: 'processing',
          lockedAt: { lt: new Date(Date.now() - 5 * 60 * 1000) },
        },
        data: { status: 'pending', lockedAt: null, scheduledAt: new Date() },
      }),
      this.prisma.emailJob.deleteMany({
        where: {
          status: 'failed',
          updatedAt: { lt: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000) },
        },
      }),
    ]);
  }

  private async deliver(
    kind: MailKind,
    recipient: string,
    payload: MailPayload,
  ) {
    if (kind === 'verification') {
      const code = this.required(payload.code, 'verification code');
      await this.transporter.sendMail({
        from: `Sukavina Portal <${this.fromAddress}>`,
        to: recipient,
        subject: 'Mã xác minh tài khoản Sukavina',
        text: `Mã xác minh của bạn là ${code}. Mã có hiệu lực trong 10 phút.`,
        html: this.codeTemplate('Xác minh tài khoản Sukavina', code),
      });
      return;
    }
    if (kind === 'password_change') {
      const code = this.required(payload.code, 'password change code');
      await this.transporter.sendMail({
        from: `Sukavina <${this.fromAddress}>`,
        to: recipient,
        subject: 'Mã OTP đổi mật khẩu Sukavina',
        text: `Mã OTP đổi mật khẩu của bạn là ${code}. Mã có hiệu lực trong 10 phút.`,
        html: this.codeTemplate('Đổi mật khẩu Sukavina', code),
      });
      return;
    }

    const employeeCode = this.required(payload.employeeCode, 'employee code');
    await this.transporter.sendMail({
      from: `Sukavina Portal <${this.fromAddress}>`,
      to: recipient,
      subject: 'Tài khoản Sukavina đã được phê duyệt',
      text: `Tài khoản ${employeeCode} đã được quản trị viên phê duyệt. Bạn có thể đăng nhập ngay bây giờ.`,
      html: `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#202124"><h2>Tài khoản đã được phê duyệt</h2><p>Tài khoản <strong>${employeeCode}</strong> đã được quản trị viên xác nhận.</p><p><a href="https://sukavinagroup.net/" style="display:inline-block;padding:12px 20px;border-radius:10px;background:#d92d27;color:#fff;text-decoration:none;font-weight:700">Đăng nhập Sukavina</a></p></div>`,
    });
  }

  private codeTemplate(title: string, code: string) {
    return `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#202124"><h2>${title}</h2><p>Mã xác minh của bạn:</p><p style="font-size:30px;font-weight:700;letter-spacing:8px">${code}</p><p>Mã có hiệu lực trong 10 phút. Không chia sẻ mã này với người khác.</p></div>`;
  }

  private required(value: string | undefined, label: string) {
    if (!value) throw new Error(`Missing ${label}`);
    return value;
  }

  private errorMessage(error: unknown) {
    return error instanceof Error ? error.message : String(error);
  }
}
