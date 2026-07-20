import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import { randomUUID } from 'crypto';
import { ContentEventsService } from '../dashboard/content-events.service';
import { PrismaService } from '../prisma/prisma.service';

const requestKinds = ['leave', 'late', 'early', 'overtime', 'business'] as const;

@Injectable()
export class RequestsService implements OnModuleInit, OnModuleDestroy {
  private timer?: NodeJS.Timeout;

  constructor(
    private readonly prisma: PrismaService,
    private readonly events: ContentEventsService,
  ) {}

  onModuleInit() {
    void this.autoApproveExpired();
    this.timer = setInterval(() => void this.autoApproveExpired(), 60_000);
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  async list(employeeId: string) {
    await this.autoApproveExpired();
    return this.prisma.employeeRequest.findMany({
      where: { employeeId }, orderBy: { createdAt: 'desc' }, take: 100,
    });
  }

  async approvals(managerEmployeeId: string) {
    await this.autoApproveExpired();
    return this.prisma.employeeRequest.findMany({
      where: { managerEmployeeId },
      include: { employee: { select: { fullName: true, employeeCode: true } } },
      orderBy: [{ status: 'asc' }, { createdAt: 'desc' }],
      take: 100,
    });
  }

  notifications(employeeId: string) {
    return this.prisma.userNotification.findMany({
      where: { recipientId: employeeId }, orderBy: { createdAt: 'desc' }, take: 100,
    });
  }

  readNotifications(employeeId: string) {
    return this.prisma.userNotification.updateMany({
      where: { recipientId: employeeId, read: false }, data: { read: true },
    });
  }

  async create(employeeId: string, input: { kind?: string; startsAt?: string; endsAt?: string; reason?: string }) {
    const kind = String(input.kind ?? '');
    const reason = String(input.reason ?? '').trim();
    const startsAt = new Date(String(input.startsAt ?? ''));
    const endsAt = new Date(String(input.endsAt ?? ''));
    if (!requestKinds.includes(kind as (typeof requestKinds)[number])) throw new BadRequestException('Loại đơn không hợp lệ');
    if (reason.length < 10 || reason.length > 1000) throw new BadRequestException('Lý do phải có từ 10 đến 1.000 ký tự');
    if (Number.isNaN(startsAt.getTime()) || Number.isNaN(endsAt.getTime()) || endsAt < startsAt) throw new BadRequestException('Khoảng thời gian không hợp lệ');

    const employee = await this.prisma.employee.findUnique({ where: { id: employeeId } });
    if (!employee) throw new NotFoundException('Không tìm thấy nhân viên');
    let manager = employee.managerEmployeeCode
      ? await this.prisma.employee.findUnique({ where: { employeeCode: employee.managerEmployeeCode } })
      : null;
    if (!manager || !manager.active || manager.id === employeeId) {
      manager = await this.prisma.employee.findFirst({
        where: { accountType: 'SUPER_ADMIN', active: true, id: { not: employeeId } },
      });
    }
    if (!manager) throw new BadRequestException('Nhân viên chưa được gán người quản lý');

    const dueAt = new Date(Date.now() + 4 * 60 * 60 * 1000);
    const request = await this.prisma.$transaction(async (tx) => {
      const created = await tx.employeeRequest.create({ data: {
        employeeId, kind, startsAt, endsAt, reason, dueAt,
        managerEmployeeId: manager.id, managerEmployeeCode: manager.employeeCode,
      } });
      await tx.userNotification.create({ data: {
        id: randomUUID(), recipientId: manager.id, type: 'request_pending', requestId: created.id,
        title: `Đơn mới từ ${employee.fullName}`,
        message: `Đơn cần được xử lý trước ${dueAt.toLocaleString('vi-VN')}.`,
      } });
      return created;
    });
    this.events.notify('request_changed');
    return request;
  }

  async decide(managerEmployeeId: string, id: string, input: { status?: string; note?: string }) {
    await this.autoApproveExpired();
    const status = String(input.status ?? '');
    const note = String(input.note ?? '').trim();
    if (!['approved', 'rejected'].includes(status)) throw new BadRequestException('Quyết định không hợp lệ');
    if (status === 'rejected' && note.length < 5) throw new BadRequestException('Vui lòng nhập lý do từ chối');
    const request = await this.prisma.employeeRequest.findUnique({ where: { id }, include: { employee: true } });
    if (!request) throw new NotFoundException('Không tìm thấy đơn');
    if (request.managerEmployeeId !== managerEmployeeId) throw new ForbiddenException('Bạn không phải người duyệt đơn này');
    if (request.status !== 'pending') throw new BadRequestException('Đơn đã được xử lý');

    const updated = await this.prisma.$transaction(async (tx) => {
      const item = await tx.employeeRequest.update({ where: { id }, data: { status, decisionNote: note || null, decidedAt: new Date() } });
      await tx.userNotification.create({ data: {
        id: randomUUID(), recipientId: request.employeeId, type: `request_${status}`, requestId: id,
        title: status === 'approved' ? 'Đơn đã được duyệt' : 'Đơn đã bị từ chối',
        message: note || 'Người quản lý đã duyệt đơn của bạn.',
      } });
      return item;
    });
    this.events.notify('request_changed');
    return updated;
  }

  async cancel(employeeId: string, id: string) {
    const request = await this.prisma.employeeRequest.findFirst({ where: { id, employeeId } });
    if (!request) throw new NotFoundException('Không tìm thấy đơn');
    if (request.status !== 'pending') throw new BadRequestException('Chỉ có thể hủy đơn đang chờ duyệt');
    const cancelled = await this.prisma.employeeRequest.delete({ where: { id } });
    this.events.notify('request_changed');
    return cancelled;
  }

  private async autoApproveExpired() {
    const expired = await this.prisma.employeeRequest.findMany({
      where: { status: 'pending', dueAt: { lte: new Date() } }, select: { id: true, employeeId: true }, take: 100,
    });
    if (!expired.length) return;
    for (const request of expired) {
      const result = await this.prisma.employeeRequest.updateMany({
        where: { id: request.id, status: 'pending' },
        data: { status: 'approved', autoApproved: true, decidedAt: new Date(), decisionNote: 'Tự động duyệt sau 4 giờ.' },
      });
      if (result.count) await this.prisma.userNotification.create({ data: {
        id: randomUUID(), recipientId: request.employeeId, type: 'request_auto_approved', requestId: request.id,
        title: 'Đơn đã được tự động duyệt', message: 'Đơn chưa được xử lý trong 4 giờ nên hệ thống đã tự động duyệt.',
      } });
    }
    this.events.notify('request_changed');
  }
}
