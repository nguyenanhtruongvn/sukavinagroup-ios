import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { ContentEventsService } from '../dashboard/content-events.service';
import { PrismaService } from '../prisma/prisma.service';

const requestKinds = ['leave', 'late', 'early', 'overtime', 'business'] as const;

@Injectable()
export class RequestsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly events: ContentEventsService,
  ) {}

  list(employeeId: string) {
    return this.prisma.employeeRequest.findMany({
      where: { employeeId },
      orderBy: { createdAt: 'desc' },
      take: 100,
    });
  }

  async create(
    employeeId: string,
    input: { kind?: string; startsAt?: string; endsAt?: string; reason?: string },
  ) {
    const kind = String(input.kind ?? '');
    const reason = String(input.reason ?? '').trim();
    const startsAt = new Date(String(input.startsAt ?? ''));
    const endsAt = new Date(String(input.endsAt ?? ''));
    if (!requestKinds.includes(kind as (typeof requestKinds)[number])) {
      throw new BadRequestException('Loại đơn không hợp lệ');
    }
    if (reason.length < 10 || reason.length > 1000) {
      throw new BadRequestException('Lý do phải có từ 10 đến 1.000 ký tự');
    }
    if (Number.isNaN(startsAt.getTime()) || Number.isNaN(endsAt.getTime()) || endsAt < startsAt) {
      throw new BadRequestException('Khoảng thời gian không hợp lệ');
    }
    const request = await this.prisma.employeeRequest.create({
      data: { employeeId, kind, startsAt, endsAt, reason },
    });
    this.events.notify('request_changed');
    return request;
  }

  async cancel(employeeId: string, id: string) {
    const request = await this.prisma.employeeRequest.findFirst({ where: { id, employeeId } });
    if (!request) throw new NotFoundException('Không tìm thấy đơn');
    if (request.status !== 'pending') {
      throw new BadRequestException('Chỉ có thể hủy đơn đang chờ duyệt');
    }
    const cancelled = await this.prisma.employeeRequest.delete({ where: { id } });
    this.events.notify('request_changed');
    return cancelled;
  }
}
