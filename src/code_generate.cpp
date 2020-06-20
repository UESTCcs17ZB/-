#include<vector>
#include<string>
#include<map>
#include<list>
#include<algorithm>
#include<iostream>
#include<fstream>
#include"header.h"
using namespace std;

extern struct Tac_list *g_tac_list;
vector<vector<Tac>> functions;
void devide() {
	auto beg = g_tac_list->tl.begin();
	for (auto it = ++g_tac_list->tl.begin(); it != g_tac_list->tl.end(); ++it) {
		//遇到一个函数的开始，函数的opcode是label，但type是返回值类型
		if (it->op_code == label && it->symb1->type != "label") {
			functions.emplace_back(beg, it);
			beg = it;
		}
	}
	functions.emplace_back(beg, g_tac_list->tl.end());
}
void alloc_stack_frame() {
	for (int i = 0; i < functions.size(); i++) {
		auto &f = functions[i];
		int offset = 4;//栈的最开始存放跳转的返回地址
		for (auto &tac : f) {
			if (tac.op_code == var_decl || tac.op_code == parameter) {
				tac.symb1->offset = offset;
				offset += 4;
			}
		}
		//为所有变量声明分配完栈内偏移量后，offset就是函数栈的大小了
		f[0].symb1->size = offset;
	}
}
void cg_arithmetic(ostream &of, Operator opcode, Symbol *s1, Symbol *s2, Symbol *s3) {	
	of << "load $2, [sp+" << s2->offset << "]" << endl;
	switch (opcode) {
	case _negate:
		of << "sub $1, $0, $2" << endl;
		of << "store sp+" << s1->offset << ", $1" << endl;
		break;
	case add://限制立即数只能出现在第三个操作数
		if (s3->kind == "literal") {
			of << "add $1, $2, " << s3->name << endl;
		} else {
			of << "load $3, [sp+" << s3->offset << "]" << endl;
			of << "add $1, $2, $3" << endl;
		}
		break;
	case subtract:
		if (s3->kind == "literal") {
			of << "sub $1, $2, " << s3->name << endl;
		} else {
			of << "load $3, [sp+" << s3->offset << "]" << endl;
			of << "sub $1, $2, $3" << endl;
		}
		break;
	case multiply:
		if (s3->kind == "literal") {
			of << "mul $1, $2, " << s3->name << endl;
		} else {
			of << "load $3, [sp+" << s3->offset << "]" << endl;
			of << "mul $1, $2, $3" << endl;
		}
		break;
	case divide:
		if (s3->kind == "literal") {
			of << "dev $1, $2, " << s3->name << endl;
		} else {
			of << "load $3, [sp+" << s3->offset << "]" << endl;
			of << "dev $1, $2, $3" << endl;
		}
		break;
	case mod:
		if (s3->kind == "literal") {
			of << "mod $1, $2, " << s3->name << endl;
		} else {
			of << "load $3, [sp+" << s3->offset << "]" << endl;
			of << "mod $1, $2, $3" << endl;
		}
		break;
	}
	of << "store sp+" << s1->offset << ", $1" << endl;
}
void cg_logic(ostream &of, Operator opcode, Symbol *s1, Symbol *s2, Symbol *s3) {
	of << "load $1, [sp+" << s2->offset << "]" << endl;
	//第三个操作数为空时，是单目的取非运算
	if (s3 != nullptr) {
		if (s3->kind == "literal") {
			of << "load $2, " << s3->name << endl;
		} else {
			of << "load $2, [sp+" << s3->offset << "]" << endl;
		}
		of << "cmp $1, $2" << endl;
	} else {
		of << "cmp $1, $0" << endl;
	}
	switch (opcode) {
	case _less:
		of << "jge pc+3" << endl;
		break;
	case _greater:
		of << "jle pc+3" << endl;
		break;
	case _less_equal:
		of << "jg pc+3" << endl;
		break;
	case _greater_equal:
		of << "jl pc+3" << endl;
		break;
	case _equal:
	case _not:
		of << "jne pc+3" << endl;
		break;
	case _not_equal:
		of << "je pc+3" << endl;
		break;
	}
	of << "store sp+" << s1->offset << ", 1" << endl;//pc+1
	of << "j pc+2" << endl;//pc+2
	of << "store sp+" << s1->offset << ", 0" << endl;//pc+3
}
void code_generate() {
	int ax = 1;
	devide();
	alloc_stack_frame();
	ofstream of("asm.txt");
	for (int i = 0; i < functions.size(); i++) {
		auto &f = functions[i];
		int frame_size = f[0].symb1->size;
		for (auto &tac : f) {
			int argu_count = 0;
			switch (tac.op_code) {
			case var_decl:
			case parameter:
				break;
			case label:
				of << tac.symb1->name << ": ";
				break;
			case argument:
				//栈从低到高依次是返回地址(由sp指向), 参数, 局部变量
				//第一个4是返回地址的位置
				if(tac.symb1->kind == "literal") {
					of << "store sp+" << frame_size + 4 + 4 * argu_count << ", " << tac.symb1->name << endl;
				} else {
					of << "load $1, [sp+" << tac.symb1->offset << "]" << endl;
					of << "store sp+" << frame_size + 4 + 4 * argu_count << ", $1" << endl;
				}
				argu_count++;
				break;
			case assignment:
				if (tac.symb2->kind == "literal") {
					of << "load $1, " << tac.symb2->name << endl;
				} else {
					of << "load $1, [sp+" << tac.symb2->offset << "]" << endl;
				}
				of << "store sp+" << tac.symb1->offset << ", $1" << endl;
				break;
			case _negate:
			case add:
			case subtract:
			case multiply:
			case divide:
			case mod:
				cg_arithmetic(of, tac.op_code, tac.symb1, tac.symb2, tac.symb3);
				break;
			case _less:
			case _greater:
			case _less_equal:
			case _greater_equal:
			case _equal:
			case _not_equal:
			case _not:
				cg_logic(of, tac.op_code, tac.symb1, tac.symb2, tac.symb3);
				break;
			case _goto:
				of << "j " << tac.symb1->name << endl;
				break;
			case ifz_goto:
				of << "load $1, [sp+" << tac.symb1->offset << "]" << endl;
				of << "cmp $1, $0" << endl;
				of << "je " << tac.symb2->name << endl;
				break;
			case call:
				of << "store sp+" << frame_size << ", pc+3" << endl;
				of << "add sp, sp, " << frame_size << endl;
				of << "j " << tac.symb2->name << endl;
				of << "sub sp, sp, " << tac.symb2->size << endl;
				of << "store sp+" << tac.symb1->offset << ", $1" << endl;
				break;
			case _return:
				if (tac.symb1 != nullptr) {
					of << "load $1, [sp+" << tac.symb1->offset << "]" << endl;
				}
				of << "j [sp]" << endl;
				break;
			default:
				break;
			}
		}
	}
}