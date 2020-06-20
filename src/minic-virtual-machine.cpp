/*
 * 模拟实现了虚拟化寄存器的计算机，指令不说明数据存放在哪个物理寄存器中，就像不需要指定数据存放在物理内存的位置一样
 * 缺点是当物理寄存器都被占用时，需要换出一个到内存里去，非常影响性能
 * 第一次使用某个虚拟寄存器时必须先进行申请，也有一定开销
 * 需要在编译期为临时变量分配虚拟寄存器号，导致无法递归调用(可以改成为临时量分配偏移量形式的虚拟寄存器号，但硬件设计上要做修改)
 * 编译器如果能控制同一时间内使用的虚拟寄存器数量小于等于物理寄存器数量，性能可以达到最优
 */

#include<iostream>
#include<fstream>
#include<string>
#include<stdio.h>
#include<vector>
#include<stdlib.h>
#include<time.h>
using namespace std;
enum Op_code {
	halt, //读到这条指令后，虚拟机退出
	//寄存器装入指令
	load_i,   //从立即数(指令寄存器)装入
	load_r,  //从寄存器装入
	load_i_m, //从立即数指向的内存空间装入
	load_r_m, //从寄存器指向的内存空间装入
	load_r_add_i_m, //栈帧的访问
	//写外存指令
	store_i_m,  //从寄存器写到立即数指向的内存空间 (全局变量的赋值)
	store_r_m,  //从寄存器写到寄存器对应的地址空间 (指针解引用赋值)
	store_add_i_m,
	//算数运算(暂只支持整型)
	add, addi, sub, subi, mul, muli, _div, divi, mod, modi, _negate,
	//影响标志寄存器的指令
	cmp,
	//分支指令, 根据标志寄存器PSW内容进行跳转
	j,
	je, jne, jl, jle, jg, jge,
	//数据传送(把寄存器内容或者指向的字符串打印到屏幕)
	out, outs,
	//特殊指令,仅在虚拟化寄存器的机器中可用，对逻辑寄存器进行分配或释放操作
	alloc, rel //对于一个逻辑寄存器，分配和释放操作都只进行一次
};
//在真正实现体系结构的时候，opcode域以外的各个bit在不同操作码下的含义要不同，这样就可以压缩指令长度了
struct Instruction {
	Op_code op;
	int rw, ra, rb;//RegisterFiles采用mips的两读一写模型，第一个操作数是要写入的寄存器编号，后两个是要读取的寄存器编号
	int imm; //立即数
	Instruction(Op_code _op, int _rw, int _ra, int _rb, int _imm) :op(_op), rw(_rw), ra(_ra), rb(_rb), imm(_imm) {}
};
//program counter，指示当前指令的地址，也就是x86里面的指令指针寄存器IP
//每次执行一条指令，pc + 1, 除此之外还会被跳转指令修改
int pc = 0;
constexpr int general_reg_num = 32;
constexpr int reg_num = general_reg_num + 2;
//状态字寄存器，equal、less、greater
bool psw_e, psw_l, psw_g;
int register_files[reg_num]; //32bit通用物理寄存器组，多的两个分别是栈寄存器sp和基址寄存器bp
#ifdef VIRTUAL_REGISTERS
int page_fault_count = 0;
int swap_out_count = 0;
int swap_in_count = 0;
struct Page_table_item {
	int va = -1;
	bool released_bit = true;
	bool accessed_bit = false;
};
//CPU中的反置页表
vector<Page_table_item> page_table(reg_num);
//完成va到va所存数据的转换，如果va不在上面的反置页表中，表示虚拟寄存器的内容现在不在物理寄存器里面
//在内存里需要有一块区域来存放这些虚拟寄存器的内容
int swap_area[1 << 10];//下标是虚拟寄存器号，里面存放的值对应虚拟寄存器的内容
//类似操作系统虚拟内存管理的CLOCK算法
int swap_out_physical_reg() {
	//找到一个已被释放的寄存器
	for (int i = 0; i < reg_num; i++) {
		if (page_table[i].released_bit == true) {
			//对于已经释放了的虚拟寄存器，不需要换出到内存，直接使用这个寄存器
			return i;
		}
	}
	swap_out_count++;
	//都被占用了,选择一个最不常用的换出，也就是最近未访问的
	for (int i = 0; i < reg_num; i++) {
		if (page_table[i].accessed_bit == false) {
			swap_area[page_table[i].va] = register_files[i];
			return i;
		}
		page_table[i].accessed_bit = false;
	}
	//如果都被占用了，随机选择一个寄存器换出
	int lucky_one = rand() % reg_num;
	swap_area[page_table[lucky_one].va] = register_files[lucky_one];
	return lucky_one;
}
int swap_in_virtual_reg(int va) {
	swap_in_count++;
	int va_data = swap_area[va];
	int index = swap_out_physical_reg();
	register_files[index] = va_data;
	page_table[index].va = va;
	page_table[index].released_bit = false;
	page_table[index].accessed_bit = true;
	return index;
}
//逻辑地址到物理地址的转换
int paging(int va) {
	for (int i = 0; i < reg_num; i++) {
		if (page_table[i].va == va) {
			return i;
		}
	}
	//缺页处理：
	page_fault_count++;
	return swap_in_virtual_reg(va);
}
int &reg(int va) {
	int index = paging(va);
	page_table[index].accessed_bit = true;
	return register_files[index];
}
//第一次使用va，分配一个物理寄存器(下面两个函数的返回值都没有作用)
int allocate(int va) {
	int index = swap_out_physical_reg();
	page_table[index].va = va;
	page_table[index].released_bit = false;
	return index;
}
int release_if_in_reg(int va) {
	for (int i = 0; i < reg_num; i++) {
		if (page_table[i].va == va) {
			page_table[i].released_bit = true;
			return i;
		}
	}
	return -1;
}
void print_summary() {
	printf("产生 %d 次缺页，从内存换入逻辑寄存器 %d 次，从物理寄存器换出到内存 %d 次\n", page_fault_count, swap_in_count, swap_out_count);
}
#else
int &reg(int index) {
	if (0 <= index && index < reg_num) {
		return register_files[index];
	}
	printf("程序错误，第 %d 行代码越界访问不存在的寄存器%d\n", pc, index);
	exit(0);
}
#endif //VIRTUAL_REGISTERS
//分开存储指令和数据
vector<Instruction> codes;
void load_codes(const string &file_name) {
	ifstream in(file_name);
	while (in) {
		int op, r1, r2, r3, imm;
		in >> op >> r1 >> r2 >> r3 >> imm;
		codes.push_back({Op_code(op), r1, r2, r3, imm});
	}
}
//20M地址空间
constexpr int mem_size = 20 * (1 << 20);
char *memory = new char[mem_size]();
int global_data_len = 0;
void load_global_data(const string &file_name) {
	ifstream in(file_name, ios::binary);
	while (in) {
		in.read(memory + global_data_len, 1);
		global_data_len++;
	}
}
char *mem(int address) {
	if (address >= mem_size) {
		printf("第 %d 行代码访问了不存在的内存空间 0x%x\n", pc, address);
		exit(0);
	}
	return memory + address;
}
bool debug_mode = true;
bool step = true;
void run() {
	while (true) {
		if (step == true) {
			string s;
			getline(cin, s);  //to_do: 可以在这里做些改进，可以根据输入，输出对应寄存器或内存的值
		}
		//取指
		auto &ins = codes[pc];
		//译码
		int rw = ins.rw, ra = ins.ra, rb = ins.rb, imm = ins.imm;
		//执行、回写
		switch (ins.op) {
		case halt:
			if (debug_mode) printf("halt\n");
			break;
		//load 的数据流动方向 rw <- ((ra、rb、imm)、[ra+imm])
		case load_i:
			if (debug_mode) printf("load imm %d to reg%d\n", imm, rw);
			reg(rw) = imm;
			break;
		case load_r:
			if (debug_mode) printf("load reg%d to reg%d\n", ra, rw);
			reg(rw) = reg(ra);
			break;
		case load_i_m:
			if (debug_mode) printf("load imm_memory [0x%x] to reg%d\n", imm, rw);
			reg(rw) = *(int *)mem(imm);
			break;
		case load_r_m:
			if (debug_mode) printf("load reg_memory [0x%x](reg%d) to reg%d\n", reg(ra), ra, rw);
			reg(rw) = *(int *)mem(reg(ra));
			break;
		case load_r_add_i_m:
			if (debug_mode) printf("load reg_add_imm_memory [0x%x](reg%d + %d) to reg%d\n", reg(ra) + imm, ra, imm, rw);
			reg(rw) = *(int *)(mem(reg(ra) + imm));
			break;
		//store的数据流动方向 ra <- rb 、 [imm] <- rb 或 [ra + imm] <- (rb, imm)
		//在mips中，busB，也就是rb对应寄存器的值连接到memory的数据端。busA(ra对应的值)通过ALU后连接到memory的地址端
		case store_i_m:
			if (debug_mode) printf("store reg%d to imm_memory [0x%x]\n", rb, imm);
			*(int *)mem(imm) = reg(rb);
			break;
		case store_r_m:
			if (debug_mode) printf("store reg%d to reg_memory [0x%x](reg%d)\n", rb, reg(ra), ra);
			*(int *)mem(reg(ra)) = reg(rb);
			break;
		case store_add_i_m:
			if (debug_mode) printf("store reg%d to reg_add_imm_memory [0x%x](reg%d + %d)", rb, reg(ra) - imm, ra, imm);
			*(int *)mem(reg(ra) + imm) = reg(rb);
			break;
		//算术运算的数据流动方向 rw <- (ra op rb) 或 rw <- (ra op imm)
		case add:
			if (debug_mode) printf("reg%d = reg%d + reg%d\n", rw, ra, rb);
			reg(rw) = reg(ra) + reg(rb);
			break;
		case addi:
			if (debug_mode) printf("reg%d = reg%d + imm%d\n", rw, ra, imm);
			reg(rw) = reg(ra) + imm;
			break;
		case sub:
			if (debug_mode) printf("reg%d = reg%d - reg%d\n", rw, ra, rb);
			reg(rw) = reg(ra) - reg(rb);
			break;
		case subi:
			if (debug_mode) printf("reg%d = reg%d - imm%d\n", rw, ra, imm);
			reg(rw) = reg(ra) - imm;
			break;
		case mul:
			if (debug_mode) printf("reg%d = reg%d * reg%d\n", rw, ra, rb);
			reg(rw) = reg(ra) * reg(rb);
			break;
		case muli:
			if (debug_mode) printf("reg%d = reg%d * imm%d\n", rw, ra, imm);
			reg(rw) = reg(ra) * imm;
			break;
		case _div:
			if (debug_mode) printf("reg%d = reg%d / reg%d\n", rw, ra, rb);
			reg(rw) = reg(ra) / reg(rb);
			break;
		case divi:
			if (debug_mode) printf("reg%d = reg%d / imm%d\n", rw, ra, imm);
			reg(rw) = reg(ra) / imm;
			break;
		case mod:
			if (debug_mode) printf("reg%d = reg%d %% reg%d\n", rw, ra, rb);
			reg(rw) = reg(ra) % reg(rb);
			break;
		case modi:
			if (debug_mode) printf("reg%d = reg%d %% imm%d\n", rw, ra, imm);
			reg(rw) = reg(ra) % imm;
			break;
		case _negate:
			if (debug_mode) printf("reg%d = -reg%d", rw, ra);
			reg(rw) = -reg(ra);
			break;
		case cmp:
			psw_e = false; psw_g = false; psw_l = false;
			if (reg(ra) == reg(rb))
				psw_e = true;
			if (reg(ra) < reg(rb))
				psw_l = true;
			if (reg(ra) > reg(rb))
				psw_g = true;
			if (debug_mode) printf("cmp; PSW: eq:%d, less:%d, greater:%d\n", psw_e, psw_l, psw_g);
			break;
		case j:
			if (debug_mode) printf("jump to 0x%x\n", imm);
			pc = imm;
			break;
		case je:
			if (debug_mode) printf("jump to 0x%x if psw_equal is true\n", imm);
			if (psw_e) pc = imm;
			break;
		case jne:
			if (debug_mode) printf("jump to 0x%x if psw_equal is false\n", imm);
			if (!psw_e) pc = imm;
			break;
		case jl:
			if (debug_mode) printf("jump to 0x%x if psw_less is true\n", imm);
			if (psw_l) pc = imm;
			break;
		case jle:
			if (debug_mode) printf("jump to 0x%x if psw_equal or less is true\n", imm);
			if (psw_e || psw_l) pc = imm;
			break;
		case jg:
			if (debug_mode) printf("jump to 0x%x if psw_greater is true\n", imm);
			if (psw_g) pc = imm;
			break;
		case jge:
			if (debug_mode) printf("jump to 0x%x if psw_equal or greater is true\n", imm);
			if (psw_e || psw_g) pc = imm;
			break;
		case out:
			printf("%d", reg(ra));
			break;
		case outs:
			printf("%s", mem(reg(ra)));
			break;
		case alloc:
		case rel:
#ifndef VIRTUAL_REGISTERS
			printf("当前机器不支持虚拟化寄存器，在编译时加入g++ -D VIRTUAL_REGISTERS 参数开启虚拟化寄存器\n");
#else
			if (ins.op == alloc) {
				int pa = allocate(rw);
				if (debug_mode) printf("allocate physical_reg%d to reg%d\n", pa, rw);
			} else {
				int pa = release_if_in_reg(rw);
				if (debug_mode) printf("release reg%d(visual reg%d)", pa, rw);
			}
#endif
			break;
		default:
			printf("在%d行读入了未知的代码\n", pc);
			break;
		}
#ifdef VIRTUAL_REGISTERS
		static int clear_access_bit_count = 0;
		//每执行50条指令，就清空一次access_bit，否则一段时间后都变成true，就没有设置accessd_bit的必要了
		if (clear_access_bit_count == 50) {
			clear_access_bit_count = 0;
			for (int i = 0; i < reg_num; i++) {
				page_table[i].accessed_bit = false;
			}
		}
#else
		if (ins.op == rel || ins.op == alloc) {
			break;
		}
#endif
		if (ins.op == j || ins.op == je || ins.op == jne || ins.op == jl || ins.op == jle || ins.op == jg || ins.op == jge) {
			continue;
		} else if (ins.op == halt || ins.op > rel) {
			break;
		}
		pc++;
	}
}
int main(int argc, const char *argv[]) {
#ifdef VIRTUAL_REGISTERS
	srand(time(nullptr)); //当寄存器都被占用，且最近都访问过，随机换出一个到内存
	printf("virtual_register_version@minic-virtual-machine\n");
#else
	printf("@minic-virtual-machine\n");
#endif
	printf("输入程序代码路径(只按下enter则使用\"./code.txt\"):");
	string cmd;
	getline(cin, cmd);
	if (cmd.size() == 0)
		cmd = "./code.txt";
	load_codes(cmd);
	printf("输入数据块路径(若没有，按下enter):");
	getline(cin, cmd);
	if (cmd.size() != 0)
		load_global_data(cmd);
	printf("是否在程序运行时输出正在执行代码的信息?(y/n)");
	getline(cin, cmd);
	if (cmd.size() != 0 && cmd != "y" && cmd != "Y") {
		debug_mode = false;
	} else {
		if (cmd.size() == 0) {
			printf("y\n");
		}
		debug_mode = true;
	}
	printf("单步运行？(y/n)");
	getline(cin, cmd);
	if (cmd.size() != 0 && cmd != "y" && cmd != "Y") {
		step = false;
	} else {
		if (cmd.size() == 0) {
			printf("y\n");
		}
		step = true;
	}
	reg(0) = 0;
	run();
#ifdef VIRTUAL_REGISTERS
	print_summary();
#endif
	return 0;
}