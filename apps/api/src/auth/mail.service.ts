import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import * as nodemailer from 'nodemailer';

@Injectable()
export class MailService {
  private readonly transporter = nodemailer.createTransport({
    host: process.env.SMTP_HOST ?? 'smtp.gmail.com',
    port: Number(process.env.SMTP_PORT ?? 465),
    secure: (process.env.SMTP_SECURE ?? 'true') === 'true',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS,
    },
  });

  async sendVerificationCode(recipient: string, code: string) {
    try {
      await this.transporter.sendMail({
        from: `Sukavina Portal <${process.env.SMTP_USER}>`,
        to: recipient,
        subject: 'Mã xác minh tài khoản Sukavina',
        text: `Mã xác minh của bạn là ${code}. Mã có hiệu lực trong 10 phút.`,
        html: `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#202124"><h2>Xác minh tài khoản Sukavina</h2><p>Mã xác minh của bạn:</p><p style="font-size:30px;font-weight:700;letter-spacing:8px">${code}</p><p>Mã có hiệu lực trong 10 phút. Không chia sẻ mã này với người khác.</p></div>`,
      });
    } catch {
      throw new ServiceUnavailableException(
        'Chưa gửi được mã xác minh. Vui lòng thử lại sau.',
      );
    }
  }

  async sendAccountApproved(recipient: string, employeeCode: string) {
    try {
      await this.transporter.sendMail({
        from: `Sukavina Portal <${process.env.SMTP_USER}>`,
        to: recipient,
        subject: 'Tài khoản Sukavina đã được phê duyệt',
        text: `Tài khoản ${employeeCode} đã được quản trị viên phê duyệt. Bạn có thể đăng nhập vào Sukavina Portal ngay bây giờ.`,
        html: `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#202124"><h2>Tài khoản đã được phê duyệt</h2><p>Tài khoản <strong>${employeeCode}</strong> đã được quản trị viên xác nhận.</p><p>Bạn có thể đăng nhập vào Sukavina Portal ngay bây giờ.</p><p><a href="https://sukavinagroup.net/" style="display:inline-block;padding:12px 20px;border-radius:10px;background:#d92d27;color:#fff;text-decoration:none;font-weight:700">Đăng nhập Sukavina Portal</a></p></div>`,
      });
    } catch {
      throw new ServiceUnavailableException(
        'Tài khoản đã được duyệt nhưng chưa gửi được email thông báo.',
      );
    }
  }
}
