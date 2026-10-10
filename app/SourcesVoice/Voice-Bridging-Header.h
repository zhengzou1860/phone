//
//  Swift 看到这个文件里的东西。故意只放 OrtShim.h：
//  onnxruntime_c_api.h 那个 OrtApi 结构体有八百多个函数指针成员，
//  让 Swift 直接导入它，在本机没有 swiftc 的情况下等于盲写。
//
#import "OrtShim.h"
