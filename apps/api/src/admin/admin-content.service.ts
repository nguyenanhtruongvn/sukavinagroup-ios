import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { assertPermission, AuthUser } from '../auth/permissions';
import { ContentEventsService } from '../dashboard/content-events.service';

@Injectable()
export class AdminContentService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly contentEvents: ContentEventsService,
  ) {}

  async list(user: AuthUser) {
    assertPermission(user, 'content.manage');
    return this.prisma.contentItem.findMany({
      orderBy: [{ page: 'asc' }, { sortOrder: 'asc' }, { createdAt: 'asc' }],
    });
  }

  async create(
    user: AuthUser,
    data: {
      page: string;
      key: string;
      title: string;
      body: string;
      sortOrder?: number;
      published?: boolean;
    },
  ) {
    assertPermission(user, 'content.manage');
    const item = await this.prisma.contentItem.create({ data });
    this.contentEvents.notify();
    return item;
  }

  async update(
    user: AuthUser,
    id: string,
    data: Partial<{
      page: string;
      key: string;
      title: string;
      body: string;
      sortOrder: number;
      published: boolean;
    }>,
  ) {
    assertPermission(user, 'content.manage');
    await this.ensureExists(id);
    const item = await this.prisma.contentItem.update({ where: { id }, data });
    this.contentEvents.notify();
    return item;
  }

  async remove(user: AuthUser, id: string) {
    assertPermission(user, 'content.manage');
    await this.ensureExists(id);
    const item = await this.prisma.contentItem.delete({ where: { id } });
    this.contentEvents.notify();
    return item;
  }

  private async ensureExists(id: string) {
    const existing = await this.prisma.contentItem.findUnique({ where: { id } });
    if (!existing) {
      throw new NotFoundException('Content item not found');
    }
  }
}
