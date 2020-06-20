%{
#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<vector>
#include<string>
#include<map>
#include<set>
#include<list>
#include<algorithm>
#include<iostream>
#include"header.h"
using namespace std;
//原来expression.y的yyin没有extern，gcc可以编译通过，但g++不行
extern FILE *yyin;
extern int yylineno;
extern "C" {
	void yyerror(const char *);
	int yylex();
}
//添加了对break、continue语句的支持
//但这两个语句有可能不在循环体里面，要对这种情况进行检查
//想到的解决方案类似引用计数
//for语句由非终结符Literal_for+循环体组成，其中Literal_for的定义是"for"
//每归约出一个Literal_for，就增加下面这个变量，归约完一个for语句，就减少这个变量
//这样在归约break和continue时，若这个变量为0，说明当前语句不在任何一个for的循环体中，编译器报错退出
int for_count = 0;
//添加了对goto语句和label声明的支持
//由于goto语句可能在label声明之前，而且可能出现多次
//因此处理方式是当遇到"goto 标识符;"时，在当前函数的符号表里查找该标识符对应的符号
//若不存在则插入，若存在则返回其在符号表中的位置。然后在tac_list里添加一个goto语句的三地址码。
//但是有一个问题：
//如果用户只定义了goto语句，而没有声明标签，程序就有语义上的错误，不像使用未定义变量的时候，上面的过程无法发现这种错误
//所以要检查goto语句是否都有了对应的label声明
//解决方案是定义下面的集合，当归约了"label :"形式的标签声明语句时，将标签名加入到集合中。
//归约完一个函数体后，遍历函数体的tac_list，对于里面的goto语句，检查第一个操作数的name是否在下面这个集合里，如果不在，则报错退出。
set<string> defined_label;
//全局"__global"有一个符号表，其他函数各自有一个符号表
//通过auto &st = symbol_tables["__global"或"函数名"]获取对符号表的引用
map<string, vector<Symbol *>> symbol_tables;
//当程序归约完毕，下面这个全局量中就是整个程序的tac列表了
//然后调用另一个.cpp文件里的函数，执行中间代码优化和目标代码生成
struct Tac_list *g_tac_list;
//作用域scope一开始是全局的，归约函数签名时，将scope设置为函数的名字
//函数由函数签名+函数体构成，函数签名会先于函数体归约
//在归约函数签名时，设置scope为函数名
//这样在归约函数体时，scope的值就是函数的名字了
//之后函数体内部的变量声明就能够正确地加入到符号表中了
string scope = "__global";
//默认先查当前的符号表，查不到去全局表查
//也可指定仅在当前的符号表查找(模式1)、仅在全局表查找(模式2)
Symbol *find_symbol(const string &name, int search_mode = 0) {
	if (search_mode != 2) {
		auto &st = symbol_tables[scope];
		for (auto &s : st) {
			if (s->name == name) {
				return s;
			}
		}
		if (search_mode == 1 || scope == "__global") {
			return nullptr;
		}
	}
	auto &st = symbol_tables["__global"];
	for (auto &s : st) {
		if (s->name == name) {
			return s;
		}
	}
	return nullptr;
}
void identifier_name_check(const string &name, int line_no = 0) {
	if (name.size() >= 2 && name[0] == '_' && name[1] == '_') {
		printf("line %d:\n双下划线开头的标识符被编译器保留，用于临时变量的生成，不能在声明语句中使用\n", line_no);
		exit(0);
	}
}
Symbol *insert_into_symbol_table(const string &name, const string &kind, const string &type) {
	auto ret = new Symbol{name, kind, type};
	symbol_tables[scope].push_back(ret);
	return ret;
}

string op_to_string(Operator op);
//类型检查，约束用户可以声明的变量类型
vector<string> legal_types = {
	"int", "float", "byte", "void"
};
void type_check(const string &type, int line_no) {
	if (find(legal_types.begin(), legal_types.end(), type) == legal_types.end()) {
		printf("line %d:\n语法错误，非法类型%s\n", line_no, type.c_str());
		exit(0);
	}
}
//"goto l1;"语句可能出现在"l1 :"语句之前, 所以处理goto l1;时，不能因为找不到l1在符号表的项就报错说l1未定义
//如果label不在符号表中，则把label插入到符号表中，如果在就直接返回
Symbol *new_goto_label(const string &name) {
	auto &st = symbol_tables[scope];
	for (auto &it : st) {
		if (it->name == name) {
			return it;
		}
	}
	auto ret = new Symbol{name, "label", "label"};
	st.push_back(ret);
	return ret;
}
Symbol *new_temp_variable(const string &type) {
	static int temp_count = 0;
	temp_count++;
	return insert_into_symbol_table("__t" + to_string(temp_count), "variable", type);
}
//用于if、for语句自动生成标签
Symbol *new_label() {
	static int label_count = 0;
	label_count++;
	string label_name = "__label" + to_string(label_count);
	defined_label.insert(label_name);
	return insert_into_symbol_table(label_name, "label", "label");
}
//对于字面量，符号表里的name是字面量的值，kind为"__literal"，以s开头的type是字符串"byte*"，没有小数点的是"int"，否则是"float"
Symbol *new_literal(const string &value) {
	auto &literal_st = symbol_tables["__literal"];
	for (auto &symb : literal_st) {
		if (symb->name == value) {
			return symb;
		}
	}
	string type;
	//根据写的lex规则，返回的字符串字面量以s开头
	if (value[0] == 's') {
		type = "string";
	} else if (find(value.begin(), value.end(), '.') != value.end()) {
		type = "float";
	} else {
		type = "int";
	}
	Symbol *ret;
	if (type != "string") {
		ret = new Symbol{value, "literal", type};
	} else {
		ret = new Symbol{value.substr(1), "literal", "byte*"};
	}
	literal_st.push_back(ret);
	return ret;
}
Tac_list *merge_tac_list(Tac_list *tac1, Tac_list *tac2) {
	if(tac1 == nullptr) {
		tac1 = new Tac_list;
	}
	if(tac2 == nullptr) {
		tac2 = new Tac_list;
	}
	//splice将tac2指向的链表移动到tac1尾后元素的前面(也就是最后一个元素的后面)
	tac1->tl.splice(tac1->end(), tac2->tl);
	return tac1;
}
vector<string> rv{
	"int","float","byte"
};
bool is_right_value(Symbol *s) {
	if(find(rv.begin(), rv.end(),s->type)==rv.end()) {
		return false;
	}
	return true;
}
Tac_list *add_binary_operation(Operator op, Tac_list *tac1, Tac_list *tac2, int line_no) {
	auto symb2 = tac1->get_result();
	auto symb3 = tac2->get_result();
	if (symb2->type != symb3->type) {
		printf("line %d:\n 运算符 %s 两边的元素类型不一致\n", line_no, op_to_string(op).c_str());
		exit(0);
	}
	if (!is_right_value(symb2)||!is_right_value(symb3)) {
		printf("line %d:\n不能对非右值%s、%s执行算术运算\n", line_no, symb2->name.c_str(), symb3->name.c_str());
		exit(0);
	}
	auto ret = merge_tac_list(tac1, tac2);
	auto temp_var = new_temp_variable(symb2->type);
	ret->push_back(Tac{var_decl, temp_var});
	ret->push_back(Tac{op, temp_var, symb2, symb3});
	return ret;
}
Tac_list *add_unary_arithmetic_or_logical_operation(Operator op, Tac_list *tac1, int line_no) {
	auto symb2 = tac1->get_result();
	if (!is_right_value(symb2)) {
		printf("line %d:\n不能对非右值%s执行算术或逻辑运算\n", line_no, symb2->name.c_str());
		exit(0);
	}
	auto temp_var = new_temp_variable(symb2->type);
	tac1->push_back(Tac{var_decl, temp_var});
	tac1->push_back(Tac{op, temp_var, symb2});
	return tac1;
}
//当第一个操作数symb1为空时，新分配一个临时变量t (存放加减运算表达式的结果)
Tac_list *add_assign_operation(Tac_list *tac1, Symbol *symb1, Symbol *symb2, int line_no = 0) {
	if (symb1 == nullptr) {
		symb1 = new_temp_variable(symb2->type);
		tac1->push_back(Tac{var_decl, symb1});
	}
	if (symb1->type != symb2->type) {
		printf("line: %d\n语法错误，赋值语句%s两侧操作数类型不一致\n", line_no, symb1->name.c_str());
		exit(0);
	}
	tac1->push_back(Tac{assignment, symb1, symb2});
	return tac1;
}
//归约参数列表时，要把参数添加到函数名对应的符号表中
//但是在归约函数签名时，是按照先归约参数列表，再规约签名的顺序(函数签名=返回值类型 函数名 '(' 参数列表 ')')
//所以在归约参数列表时，还不知道应该将参数插入到哪个符号表
//因此将其类型信息暂存到这个结构体中
struct Parameter_name_type_list {
	vector<Symbol> pl;
	decltype(pl.begin()) begin() { return pl.begin(); }
	decltype(pl.end()) end() { return pl.end(); }
	void push_back(const string &name, const string &type) {
		pl.push_back(Symbol{name, "parameter", type});
	}
};
//由于实参列表可以由表达式组成，所以在归约实参列表时，要记录表达式的tac列表及其结果
//在函数调用时，先运行表达式的tac列表，再将其结果入栈
struct Argument_tac_result_list {
	Tac_list *tl;
	vector<Symbol *> *results;
	Argument_tac_result_list() :tl(new Tac_list), results(new vector<Symbol *>) {}
	~Argument_tac_result_list() {
		delete tl;
		delete results;
	}
	void splice_tac_list(Tac_list *tac1) {
		tl = merge_tac_list(tl, tac1);
	}
	void push_back_symbol(Symbol *s) {
		results->push_back(s);
	}
};
//只是在最后打印的时候用，把临时变量前面的双下划线去掉会好看点
string remove_under_line(const string &s) {
	if(s.size()>=2 && s[0]=='_' && s[1]=='_'){
		return s.substr(2);
	}
	return s;
}
%}
%error-verbose	//更详细的报错
%union {
	char *str;
	struct Name_list *name_list;
	struct Parameter_name_type_list *parameter_name_type_list;
	struct Argument_tac_result_list *argument_tac_result_list;
	struct Tac_list *tac_list;
}

%token <str> literal_nums
%token <str> literal_str
%type <str> Literal
%token <str> identifier
%token op_equal
%token op_not_equal
%token op_less_equal
%token op_greater_equal
%token literal_if
%token literal_else
%token literal_goto
%token literal_for
%type <str> Literal_for
%token literal_return
%token indent_inc
%token indent_dec
%token literal_break
%token literal_continue

%type <name_list> Identifier_list
%type <parameter_name_type_list> Parameter_list
%type <argument_tac_result_list> Argument_list

%type <tac_list> Function_call
%type <tac_list> Expression
%type <tac_list> Assignment
%type <tac_list> If_stmt
%type <tac_list> Else_stmt
%type <tac_list> Label_stmt
%type <tac_list> Goto_stmt
%type <tac_list> Break_stmt
%type <tac_list> Continue_stmt
%type <tac_list> For_stmt
%type <tac_list> Var_declaration
%type <tac_list> Statement
%type <tac_list> Statements
%type <tac_list> Return_stmt
%type <tac_list> Function_signature
%type <tac_list> Function_decl
%type <tac_list> Top_level_decl
%type <tac_list> Top_level_decls

%right '='
%left op_equal op_not_equal
%left '<' '>' op_less_equal op_greater_equal
%left '+' '-'
%left '*' '/' '%'
%right op__negate op_dereference '!'

%%
start: 
	Top_level_decls {
		g_tac_list = $1;
		cout << "symbol tables:" << endl;
		for(auto &it:symbol_tables) {
			string name = it.first;
			auto &st = it.second;
			cout << "\"" << remove_under_line(name) << "\":" << endl;
			for(auto symb:st) {
				cout << remove_under_line(symb->name) << "  " 
					<< remove_under_line(symb->kind) << " " 
					<< remove_under_line(symb->type) << endl;
			}
			cout << endl;
		}
		cout << endl;
		cout<<"tac list:"<<endl;
		for(auto &t:*$1) {
			auto op = t.op_code;
			string name1,name2,name3;
			if(t.symb1 != nullptr) {
				name1 = remove_under_line(t.symb1->name);
			}
			if(t.symb2 != nullptr) {
				name2 = remove_under_line(t.symb2->name);
			}
			if(t.symb3 != nullptr) {
				name3 = remove_under_line(t.symb3->name);
			}
			if(op <= argument) {
				if(op==label) {
					cout << name1 <<" :" << endl;
				} else {
					cout << op_to_string(op) << " " << name1 << endl;
				}
				
			} else if(op == assignment) {
				cout << name1 << " = " << name2 << endl;
			} else if(op <= _not) {
				cout << name1 << " = " << op_to_string(op) << " " << name2 <<endl;
			} else if(op <= _not_equal) {
				cout << name1 << " = " << name2 << " " << op_to_string(op) << " " << name3 <<endl;
			} else if(op == _goto) {
				cout << "goto " << name1 << endl;
			} else if(op == ifz_goto) {
				cout << "ifz " << name1 << " goto " << name2 <<endl;
			} else if(op == call) {
				if(t.symb1 != nullptr) {
					cout << name1 << " = ";
				}
				cout << "call " << name2 << endl;
			} else if(op == _return) {
				cout << "return ";
				if(t.symb1 != nullptr) {
					cout << name1;
				}
				cout << endl;
			} else if(op > not_set) {
				cout << "错误的三地址码" << endl;
			}
		}
	}
;
Top_level_decls: 
	Top_level_decl {
		$$ = $1;
	}
	| Top_level_decls Top_level_decl {
		$$ = merge_tac_list($1, $2);
	}
;
Top_level_decl:
	//为了方便代码生成，禁用了全局变量
	// Var_declaration ';' {
	//	$$ = $1;
	//}
	//| 
	Function_decl {
		$$ = $1;
	}
;
Var_declaration:
	identifier Identifier_list {//int a,b,c;
		$$ = new Tac_list;
		type_check($1, @1.first_line);
		for(auto &id:*($2)) {
			identifier_name_check(id, @2.first_line);
			if(find_symbol(id, 1) != nullptr) {
				printf("line %d:\n语法错误，变量: %s 重定义\n", @2.first_line, id.c_str());
				exit(0);
			}
			auto new_symbol = insert_into_symbol_table(id, "variable", $1);
			$$->push_back(Tac{var_decl, new_symbol});
		}
		free($1);
		delete $2;
	}
;
Identifier_list: 
	identifier {
		$$ = new Name_list;	//第一次归约要为$$分配空间
		$$->push_back($1);
		free($1);
	}
	| Identifier_list ',' identifier {
		$$ = $1;	//$1已归约过，指向一个可用的vector
		$$->push_back($3);
		free($3);
	}
;
Function_decl:
	Function_signature indent_inc Statements Return_stmt ';' indent_dec {
		$3->check_label();
		$$ = merge_tac_list($1, $3);
		$$ = merge_tac_list($$, $4);
		auto &tac_return = *(--$$->end());
		auto &func_signature = *($$->begin())->symb1;
		//第一项tac里是标签的声明语句
		//第一个操作数的三个值分别是: name:函数名, kind:label, type:返回值类型
		if(func_signature.type == "void") {
			if(tac_return.symb1 != nullptr) {
				printf("line %d:\n语法错误：返回值为空的函数 %s 不能返回一个值。\n", @4.first_line, scope.c_str());
				exit(0);
			}
		} else {
			if(tac_return.symb1 == nullptr) {
				printf("line %d:\n语法错误，有返回值的函数 %s 必须返回一个值\n", @1.first_line, scope.c_str());
				exit(0);
			}
			if(func_signature.type != tac_return.symb1->type) {
				printf("line %d:\n语法错误，return语句返回的值类型与函数 %s 的签名不匹配\n", @4.first_line, scope.c_str());
				exit(0);
			}
		}
	}
;
Function_signature:
	identifier identifier '(' Parameter_list ')' {
		$$ = new Tac_list;
		scope = "__global";
		type_check($1, @1.first_line);
		identifier_name_check($2, @2.first_line);
		if(find_symbol($2, 2) != nullptr) {
			printf("line %d:\n语法错误，变量: %s 重定义\n", @2.first_line, $2);
			exit(0);
		}
		auto function_signature_symbol = insert_into_symbol_table($2, "label", $1);
		$$->push_back(Tac{label, function_signature_symbol});
		scope = $2;
		if($4 != nullptr) {
			for(auto &para:*$4) {
				identifier_name_check(para.name, @4.first_line);
				if(find_symbol(para.name, 1) != nullptr) {
					printf("line %d:\n语法错误，变量: %s 重定义\n", @4.first_line, para.name.c_str());
					exit(0);
				}
				type_check(para.type, @4.first_line);
				auto new_para_symbol = insert_into_symbol_table(para.name, "parameter", para.type);
				$$->push_back(Tac{parameter, new_para_symbol});
			}
			delete $4;
		}
		free($1);
		free($2);
	}
;
Parameter_list:
	identifier identifier { //int a
		$$ = new Parameter_name_type_list;
		$$->push_back($2, $1);
		free($1);
		free($2);
	}
	| Parameter_list ',' identifier identifier {   //int a, int b
		if($1 == nullptr) {
			$$ = new Parameter_name_type_list;
		} else {
			$$ = $1;
		}
		$$->push_back($4, $3);
		free($3);
		free($4);
	}
	| {
		$$ = nullptr;
	}
;
Statements:
	Statement {
		$$ = $1;
	}
	| Statements Statement {
		$$ = merge_tac_list($1, $2);
	}
;
Statement:
	Var_declaration ';' { $$ = $1; }
	| Assignment ';' { $$ = $1; }
	| If_stmt { $$ = $1; }
	| Label_stmt { $$ = $1; }
	| Goto_stmt ';' { $$ = $1; }
	| For_stmt { $$ = $1; }
	| Break_stmt ';' { $$ = $1; }
	| Continue_stmt ';' { $$ = $1; }
	| Function_call ';' { $$ = $1; }
;
Return_stmt:
	literal_return Expression {
		auto symb1 = $2->get_result();
		$$ = new Tac_list;
		$$ = merge_tac_list($$, $2);
		$$->push_back(Tac{_return, symb1});
	}
	| literal_return {
		$$ = new Tac_list;
		$$->push_back(Tac{_return});
	}
;
If_stmt:
	literal_if Expression indent_inc Statements indent_dec Else_stmt {
		//对于if语句，要先归约else部分，因为条件不成立时要跳转到else的开头，知道跳转的目标位置后能方便一些
		auto condition = $2->get_result();
		//else块存在
		if($6 != nullptr) {
			//else块的第一句是jump到else末尾，当条件为真时，程序执行完if块后，就会执行这句话
			//第二句是label，当if条件为假时跳转到此处
			auto jump_if_false = (++$6->begin())->symb1;
			//当条件为假时跳转的三地址码
			$2->push_back(Tac{ifz_goto, condition, jump_if_false});
			$$ = merge_tac_list($2, $4);
			$$ = merge_tac_list($$, $6);
		} else {
			auto jump_if_false = new_label();
			$2->push_back(Tac{ifz_goto, condition, jump_if_false});
			$$ = merge_tac_list($2, $4);
			//条件为假时跳转到此处
			$$->push_back(Tac{label, jump_if_false});
		}
	}
;
Else_stmt:
	literal_else indent_inc Statements indent_dec {
		auto jump_if_false = new_label();
		auto else_end = new_label();
		$$ = new Tac_list;
		$$->push_back(Tac{_goto, else_end});
		$$->push_back(Tac{label, jump_if_false});
		$$ = merge_tac_list($$, $3);
		$$->push_back(Tac{label, else_end});
	}
	| { //else部分可为空
		$$ = nullptr;
	}
;
Literal_for:
	literal_for { for_count++; }
;
For_stmt:
	//for i < n 
	//相当于while
	Literal_for Expression indent_inc Statements indent_dec { 
		for_count--;
		$$ = new Tac_list;
		auto for_begin = new_label();
		auto for_end = new_label();
		$4->adjust_continue_and_break(for_begin, for_end);
		$$->push_back(Tac{label, for_begin});
		auto condition = $2->get_result();
		$$ = merge_tac_list($$, $2);
		$$->push_back(Tac{ifz_goto, condition, for_end});
		$$ = merge_tac_list($$, $4);
		$$->push_back(Tac{_goto, for_begin});
		$$->push_back(Tac{label, for_end});
	}
	//传统的for
	| Literal_for Assignment ';' Expression ';' Assignment indent_inc Statements indent_dec {
		for_count--;
		$$ = new Tac_list;
		//初始化语句
		$$ = merge_tac_list($$, $2);
		auto for_begin = new_label();
		auto for_end = new_label();
		$8->adjust_continue_and_break(for_begin, for_end);
		$$->push_back(Tac{label, for_begin});
		auto condition = $4->get_result();
		//条件语句
		$$ = merge_tac_list($$, $4);
		$$->push_back(Tac{ifz_goto, condition, for_end});
		//循环体
		$$ = merge_tac_list($$, $8);
		//收尾处理
		$$ = merge_tac_list($$, $6);
		$$->push_back(Tac{_goto, for_begin});
		$$->push_back(Tac{label, for_end});
	}
;
Break_stmt:
	literal_break {
		if(for_count == 0) {
			printf("line %d:\n语法错误，break语句只能出现在for语句中\n", @1.first_line);
			exit(0);
		}
		$$ = new Tac_list;
		//暂时为空的break三地址码，在归约for语句时，遍历循环体的Tac_list，将空break的第一项指向for语句结尾的label
		//并将op_code的break改为goto
		$$->push_back(Tac{_break});
	}
;
Continue_stmt:
	literal_continue {
		if(for_count == 0) {
			printf("line %d:\n语法错误，continue语句只能出现在for语句中\n", @1.first_line);
			exit(0);
		}
		$$ = new Tac_list;
		$$->push_back(Tac{_continue});
	}
;
Assignment: 
	identifier '=' Expression {
		auto symb1 = find_symbol($1);
		if(symb1 == nullptr) {
			printf("line %d:\n%s 未定义\n", @1.first_line, $1);
			exit(0);
		}
		$$ = add_assign_operation($3, symb1, $3->get_result(), @1.first_line);
		free($1);
	}
	| identifier '=' Assignment {
		auto symb1 = find_symbol($1);
		if(symb1 == nullptr) {
			printf("line %d:\n%s 未定义\n", @1.first_line, $1);
			exit(0);
		}
		$$ = add_assign_operation($3, symb1, $3->get_result(), @1.first_line);
		free($1);
	}
;
Expression:
	identifier { 
		auto symb1 = find_symbol($1);
		if(symb1 == nullptr) {
			printf("line %d:\n %s 未定义\n", @1.first_line, $1);
			exit(0);
		}
		$$ = new Tac_list;
		$$->push_back(Tac{not_set, symb1});
		free($1);
	}
	| Literal {
		auto symb1 = new_literal($1);
		$$ = new Tac_list;
		$$->push_back(Tac{not_set, symb1});
		free($1);
	}
	| '(' Expression ')' { $$ = $2; }
	//此处的'-'与op__negate具有相同的优先级
	| '-' Expression %prec op__negate { $$ = add_unary_arithmetic_or_logical_operation(_negate, $2, @1.first_line); } 
	| '!' Expression { $$ = add_unary_arithmetic_or_logical_operation(_not, $2, @1.first_line); }
	| Expression '+' Expression { $$ = add_binary_operation(add, $1, $3, @1.first_line); }
	| Expression '-' Expression { $$ = add_binary_operation(subtract, $1, $3, @1.first_line); }
	| Expression '*' Expression { $$ = add_binary_operation(multiply, $1, $3, @1.first_line); }
	| Expression '/' Expression { $$ = add_binary_operation(divide, $1, $3, @1.first_line); }
	| Expression '%' Expression { $$ = add_binary_operation(mod, $1, $3, @1.first_line); }
	| Expression '<' Expression { $$ = add_binary_operation(_less, $1, $3, @1.first_line); }
	| Expression '>' Expression { $$ = add_binary_operation(_greater, $1, $3, @1.first_line); }
	| Expression op_less_equal Expression { $$ = add_binary_operation(_less_equal, $1, $3, @1.first_line); }
	| Expression op_greater_equal Expression { $$ = add_binary_operation(_greater_equal, $1, $3, @1.first_line); }
	| Expression op_equal Expression { $$ = add_binary_operation(_equal, $1, $3, @1.first_line); }
	| Expression op_not_equal Expression { $$ = add_binary_operation(_not_equal, $1, $3, @1.first_line); }
	| Function_call { 
		auto result = $1->get_result();
		if(result == nullptr) {
			printf("line %d:\n返回值为空的函数不能作为表达式使用\n", @1.first_line);
		}
		$$ = $1; 
	}
;
Literal:
	literal_nums { $$ = $1; }
	| literal_str { $$ = $1; }
;
Function_call:
	identifier '(' Argument_list ')' { //增加了参数检查的功能
		$$ = new Tac_list;
		auto func = find_symbol($1, 2);
		if(func == nullptr) {
			printf("line %d :\n调用了未声明的函数%s\n", @1.first_line, $1);
			exit(0);
		}
		if(func->kind != "label") {
			printf("line %d\n%s 不是一个函数\n", @1.first_line, $1);
		}
		//统计被调函数的参数类型
		vector<string> paras;
		auto &st = symbol_tables[func->name];
		for(auto it = st.begin(); (*it)->kind == "parameter"; ++it) {
			paras.push_back((*it)->type);
		}
		if($3 != nullptr) {
			if($3->results->size()!=paras.size()) {
				printf("line %d:\n参数个数错误，函数%s需要%d个参数，但提供了%d个\n", @1.first_line, $1, int(paras.size()), int($3->results->size()));
				exit(0);
			}
			//参数值的计算语句
			$$ = merge_tac_list($$, $3->tl);
		} else {
			if(paras.size() != 0) {
				printf("line %d :函数%s需要%d个参数\n", @1.first_line, $1, int(paras.size()));
				exit(0);
			}
		}
		//将函数的返回值保持在这里
		Symbol *temp;
		if(func->type != "void") {
			temp = new_temp_variable(func->type);
			$$->push_back(Tac{var_decl, temp});
		}
		//顺序压栈
		auto para = paras.begin();
		if($3 != nullptr) {
			for(int i = 0; i < $3->results->size(); i++) {
				if($3->results->at(i)->type != *para) {
					printf("line %d :\n第%d个参数类型是%s, 但函数要求%s类型的参数\n", @1.first_line, i+1, $3->results->at(i)->type.c_str(), para->c_str());
				}
				++para;
				$$->push_back(Tac{argument, $3->results->at(i)});
			}
		}
		if(func->type != "void"){
			$$->push_back(Tac{call, temp, func});
		} else {
			$$->push_back(Tac{call, nullptr, func});
		}
		free($1);
	}
;
Argument_list:
	Expression {
		$$ = new Argument_tac_result_list;
		auto arg_symbol = $1->get_result();
		$$->splice_tac_list($1);
		$$->push_back_symbol(arg_symbol);
	}
	| Argument_list ',' Expression {
		auto arg_symbol = $3->get_result();
		$1->splice_tac_list($3);
		$1->push_back_symbol(arg_symbol);
		$$ = $1;
	}
	| {
		$$ = nullptr;
	}
;
Label_stmt:
	identifier ':' {
		$$ = new Tac_list;
		identifier_name_check($1, @1.first_line);
		if(find_symbol($1, 1) != nullptr) {
			printf("line %d:\n语法错误，变量: %s 重定义\n", @1.first_line, $1);
			exit(0);
		}
		auto label_symbol = insert_into_symbol_table($1, "label", "label");
		$$->push_back(Tac{label, label_symbol});
		defined_label.insert($1);
		free($1);
	}
;
Goto_stmt: 
	literal_goto identifier {
		identifier_name_check($2, @2.first_line);
		auto label_symbol = new_goto_label($2);
		$$ = new Tac_list;
		$$->push_back(Tac{_goto, label_symbol});
		free($2);
	}
;
%%
void yyerror(const char *s) {
	printf("line %d:\n%s\n", yylineno, s);
	exit(0);
}
string op_to_string(Operator op) {
	switch(op) {
		case var_decl: return "Var"; break;
		case label: return "Label:"; break;
		case parameter: return "Para"; break;
		case argument: return "Arg"; break;
		case assignment: return "="; break;
		case _negate: return "-"; break;
		case _not: return "!"; break;
		case add: return "+"; break;
		case subtract: return "-"; break;
		case multiply: return "*"; break;
		case divide: return "/"; break;
		case mod: return "%"; break;
		case _less: return "<"; break;
		case _greater: return ">"; break;
		case _less_equal: return "<="; break;
		case _greater_equal: return ">="; break;
		case _equal: return "=="; break;
		case _not_equal: return "!="; break;
		case _goto: return "goto"; break;
		case ifz_goto: return "ifz_goto"; break;
		case call: return "call"; break;
		case _return: return "return"; break;
		default: return "error";
	}
}
int main(int argc, const char *argv[]) {
	if(argc != 2) {
		printf("usage: %s filename\n", argv[0]);
		exit(0);
	}			
	if((yyin = fopen(argv[1], "r")) == NULL ) {
		printf("open file %s failed\n", argv[1]);
		exit(0);
	}
	yyparse();
	extern void code_generate();
	code_generate();
	fclose(yyin);
	return 0;
}
