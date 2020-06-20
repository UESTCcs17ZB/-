#include<vector>
#include<string>
#include<list>
#include<set>
//identifier_list的语义值类型为vector<string>*
//如果在%union里写std::vector<std::string> *nl;编译器会报错
//因为包含上述语义值声明的.h头文件会include到lex里
//但是lex里没有包含vector和string的头文件(也可以加在lex生成的.c文件的第一行)
//所以把对vector<string>的操作封装进一个结构体
//再在%union里写struct Name_list *name_list; 就不会报错了
struct Name_list {
	std::vector<std::string> nl;
	decltype(nl.begin()) begin() { return nl.begin(); }
	decltype(nl.end()) end() { return nl.end(); }
	void push_back(const std::string &s) { nl.push_back(s); }
};
struct Symbol {
	//"int a"      ->  name: a,      kind: variable, type: int
	//"loop:"      ->  name: loop,   kind: label,    type: label
	//"int main()" ->  name: main,   kind: label,    type: int
	//"123456"     ->  name: 123456, kind: literal,  type: int
	std::string name;
	std::string kind;
	std::string type;
	//以下变量在目标代码生成阶段使用
	int size = 4;	//对于变量，目前的size均为4。对于函数，size是栈帧大小
	int offset;		//对于变量，offset是栈帧内的偏移量(ebp-8的第二个数)
	Symbol(const std::string &n = "", const std::string &k = "", const std::string &t = "") 
		:name(n), kind(k), type(t) { }
};
enum Operator {
	var_decl, label, parameter, argument, //说明类
	//运算类，一元运算
	assignment, _negate, _not,
	//二元运算，加下划线避免与c++库冲突
	add, subtract, multiply, divide, mod, _less, _greater, _less_equal, _greater_equal, _equal, _not_equal,
	//转移类
	_goto, ifz_goto, _break, _continue,
	call, _return,
	not_set	//仅为tac_list保存标识符在符号表中的位置，在代码生成时不处理这个tac
};
struct Tac {
	Operator op_code;
	Symbol *symb1;
	Symbol *symb2;
	Symbol *symb3;
	Tac(Operator op = not_set, Symbol *s1 = nullptr, Symbol *s2 = nullptr, Symbol *s3 = nullptr)
		:op_code(op), symb1(s1), symb2(s2), symb3(s3) {
	}
};
//封装的原因与indentifier_list相同，此外新增了三个操作
struct Tac_list {
	std::list<Tac> tl;
	decltype(tl.begin()) begin() { return tl.begin(); }
	decltype(tl.end()) end() { return tl.end(); }
	void push_back(const Tac &tac) { tl.push_back(tac); }
	//查找当前tac_list最后一个tac的第一个操作数在符号表的位置
	//这个操作数里存放了结果
	Symbol *get_result() {
		auto last_tac = tl.end();
		if (last_tac != tl.begin()) {
			--last_tac;
			return last_tac->symb1;
		}
		return nullptr;
	}
	//由于在归约for语句的循环体时，会有break和continue语句
	//在归约这两个语句时，for还没有完成归约，也就是说不知道跳转的目的地址，只能先置为空
	//当归约完for的循环体时，对循环体的tac_list调用这个函数，传入for的起始标签和终结标签
	//然后将空continue的目的设置为起始标签，空break的目的设置为终结标签
	void adjust_continue_and_break(Symbol *for_begin, Symbol *for_end) {
		for (auto &tac : tl) {
			if (tac.op_code == _continue) {
				tac.symb1 = for_begin;
				tac.op_code = _goto;
			} else if (tac.op_code == _break) {
				tac.symb1 = for_end;
				tac.op_code = _goto;
			}
		}
	}
	//检查goto的label操作数是否都有对应的"label :"声明
	void check_label() {
        extern std::set<std::string> defined_label;
		for (auto &tac : tl) {
			if (tac.op_code == _goto) {
				std::string &label_name = tac.symb1->name;
				if (defined_label.find(label_name) == defined_label.end()) {
					printf("语法错误，标签: %s 未定义\n", label_name.c_str());
					exit(0);
				}
			}
		}
		defined_label.clear();
	}
};