import prisma from "../utils/prisma";
import { getPaymentProvider } from "../providers/payment";
import { EscrowStatus, PaymentMethod, Transaction } from "../types/domain";
import { AppError } from "../utils/errors";

// freezeFunds is the dispute entry — only HELD escrows can be disputed.
// release/refund are also called from the dispute → resolve path, so they
// additionally accept DISPUTED.
const HELD: EscrowStatus[] = ["HELD"];
const HELD_OR_DISPUTED: EscrowStatus[] = ["HELD", "DISPUTED"];

export class EscrowService {
  /**
   * Hold funds in escrow when a task contract is created.
   */
  async holdFunds(taskContractId: string, amount: number, currency: string): Promise<Transaction> {
    const provider = getPaymentProvider();

    const result = await provider.holdEscrow(amount, currency, { taskContractId });

    if (result.status !== "held") {
      throw new AppError(502, "Payment provider failed to hold escrow");
    }

    return prisma.transaction.create({
      data: {
        taskContractId,
        amount,
        currency,
        paymentMethod: provider.name.toUpperCase() as PaymentMethod,
        escrowStatus: "HELD",
        externalRef: result.externalRef,
      },
    });
  }

  /**
   * Release escrowed funds to the seller on task completion.
   */
  async releaseFunds(taskContractId: string): Promise<Transaction> {
    const tx = await this.findActive(taskContractId, HELD_OR_DISPUTED);
    const provider = getPaymentProvider();

    const result = await provider.releaseEscrow(tx.externalRef!);
    if (result.status !== "released") {
      throw new AppError(502, "Payment provider failed to release escrow");
    }

    return prisma.transaction.update({
      where: { id: tx.id },
      data: {
        escrowStatus: "RELEASED",
        releasedAt: new Date(),
      },
    });
  }

  /**
   * Refund escrowed funds to the buyer on task failure/cancellation.
   */
  async refundFunds(taskContractId: string): Promise<Transaction> {
    const tx = await this.findActive(taskContractId, HELD_OR_DISPUTED);
    const provider = getPaymentProvider();

    const result = await provider.refundEscrow(tx.externalRef!);
    if (result.status !== "refunded") {
      throw new AppError(502, "Payment provider failed to refund escrow");
    }

    return prisma.transaction.update({
      where: { id: tx.id },
      data: {
        escrowStatus: "REFUNDED",
        refundedAt: new Date(),
      },
    });
  }

  /**
   * Freeze funds during a dispute.
   */
  async freezeFunds(taskContractId: string, reason: string): Promise<Transaction> {
    const tx = await this.findActive(taskContractId, HELD);

    return prisma.transaction.update({
      where: { id: tx.id },
      data: {
        escrowStatus: "DISPUTED",
        disputeReason: reason,
      },
    });
  }

  async getByTaskContract(taskContractId: string): Promise<Transaction[]> {
    return prisma.transaction.findMany({
      where: { taskContractId },
      orderBy: { createdAt: "desc" },
    });
  }

  private async findActive(
    taskContractId: string,
    allowedStatuses: EscrowStatus[]
  ): Promise<Transaction> {
    const tx = await prisma.transaction.findFirst({
      where: { taskContractId, escrowStatus: { in: allowedStatuses } },
    });

    if (!tx) {
      throw new AppError(404, `No active escrow found for task contract: ${taskContractId}`);
    }

    return tx;
  }
}

export const escrowService = new EscrowService();
