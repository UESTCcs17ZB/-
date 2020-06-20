# compiler-engineering  
为了练习学到编译原理知识写的toy langue编译器  
前端使用lex和yacc，中间代码的格式是三地址码tac，后端写得比较简单，没做优化  
还没有编写汇编器，只能手动将汇编代码转换为机器码  

使用方式：  
生成汇编代码文件asm.txt  
./minic source_file  
此外上面的命令会将三地址码及符号表信息打印到屏幕上，可以使用输出重定位保存到文件中  
./minic source_file > a.tac  

语法规则与C语言基本一致，但只支持int和void(在语法分析阶段可以支持float，但在目标代码生成阶段不能生成汇编代码)  
使用python风格缩进  
使用go风格的for语句(结合while和for的用法)  
for、if语句可以不写小括号，但必须换行  
return只能且必须出现在函数末尾  
  
eg:  
```
int fib(int n)  
  int ret;  
  if n<2  
    ret = n;  
  else  
    ret = fib(n-1)+fib(n-2);  
  return ret;  
void main()
  int f;  
  f=fib(5);  
  return;  
```
