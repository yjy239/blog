---
title: Android重学系列 二叉搜索树
top: false
cover: false
date: 2019-03-17 15:58:23
img:
tag:
description:
author: yjy239
summary:
categories: 算法
tags:
- 算法
---
# 背景
Binder这一块涉及的比较广，囫囵吞枣的讲，结果只会把字数堆上多高我不清楚。清楚的是，这样阅读起来吃力。而Binder涉及的知识面比较广，在Binder驱动下层使用到了红黑树，因此我将提前讲红黑树算法（相当于知识点捡漏吧）。本来这个算法专题，我准备是说完四大组件的源码原理之后，开启的一个新的专栏。为了说清楚这个Binder，我提前梳理一遍我所理解的红黑树。但是思考了半天，感觉如果连二叉搜索树都讲不清，怎么讲红黑树呢？计划这个专题会讨论二叉搜索树，avl树，最后才是红黑树。之后会慢慢的补上b+树这些的。

# 正文
## 二叉树

什么是树？

>树是一张数据结构。它是由n（n>=1）个有限结点组成一个具有层次关系的。把它叫做“树”是因为它看起来像一棵倒挂的树，也就是说它是根朝上，而叶朝下的。它具有以下的特点：每个节点都有着零个或者多个子节点；没有父结点的结点称为根结点；每一个非根结点有且只有一个父结点；除了根结点外，每个子结点可以分为多个不相交的子树；

其中二叉树在这个定义上，再进一步的扩展：
>每个节点最多含有两个子树的树称为二叉树.二叉树的子树有左右之分，次序不能颠倒。

关于二叉树，又衍生出了一些有趣的性质。

- 二叉树的第i层至多有$2^i-1$个结点(i>=1);
- 深度为h的二叉树最多有$2^h-1$个结点(h>=1)，最少有h个结点
- 对于任意一棵二叉树，如果其叶结点数为N0，而度数为2的结点总数为N2，则N0=N2+1;
- 具有n个结点的完全二叉树的深度为log2(n+1);
- 有N个结点的完全二叉树各结点如果用顺序方式存储，则结点之间有如下关系：
　　　　若I为结点编号则 如果I>1，则其父结点的编号为I/2；
　　　　如果2I<=N，则其左儿子（即左子树的根结点）的编号为2I；若2I>N，则无左儿子；
　　　　如果2I+1<=N，则其右儿子的结点编号为2I+1；若2I+1>N，则无右儿子。
- 给定N个节点，能构成h(N)种不同的二叉树，其中h(N)为卡特兰数的第N项，h(n)=C(2*n, n)/(n+1)。
- 设有i个枝点，I为所有枝点的道路长度总和，J为叶的道路长度总和J=I+2i。


## 二叉搜索树

二叉搜索树定义：
- 1 若左子树不空，则左子树上所有结点的值均小于它的根结点的值；
- 2 若右子树不空，则右子树上所有结点的值均大于或等于它的根结点的值；
- 3 左、右子树也分别为二叉排序树；
- 4 没有键值相等的节点。

为什么我们需要这么一个数据结构。试想想，当我们尝试的查找某个数据的时候，如果按照上面的定义，我们只要在某个数据时候，小的往左边找，大的往右边找，比起普通的链表，二叉搜索树的时间复杂度从O(n)到O(log2n)级别。而影响树的查找速度往往是树的高度。

拥有这点我们就很有必要对二叉搜索树进行学习。而且之后很多性能更强树都是从这个基础上向上发展的。

接下里我会根据二叉搜索树，分别用c++来写出增删查三个步骤。

#### 二叉搜索树数据结构的定义

我先思考一下，我们如果需要用一个数据结构定义一个树，需要东西才能很好的表达这个概念。根据概念，我们需要定义树上的节点。
每个节点拥有如下内容：
- 1.键值对。
- 2.我们要去寻找左右树，那么就必须有分别代表左右树的对象。

对于二叉搜索树，好像不需要更多的东西了。那么我们定义一个TreeNode的类。

###### 文件：
TreeNode.h
```
#ifndef TREE_TREENODE_H
#define TREE_TREENODE_H

#include <cwchar>

template <class K,class V>
class TreeNode{
public:
    TreeNode *left = NULL;
    TreeNode *right = NULL;
    K key;
    V value;

    TreeNode(TreeNode* node){
        this->left = node->left;
        this->right = node->right;
        this->key = node->key;
        this->value = node->value;
    }

    TreeNode(K key,V value){
        this->left = NULL;
        this->right = NULL;
        this->key = key;
        this->value = value;

    }

};

#endif //TREE_TREENODE_H
```

多一个节点传入的构造函数是为了后面的方便。

### 二叉搜索树的插入
那么我们开始构造整个二叉树的插入方法。思路很简单，我们扣着定义前进。
![二叉搜索树添加过程.png](/images/二叉搜索树添加过程.png)
```
 
    TreeNode<K,V>* addNode(TreeNode<K,V> *pNode,K key,V value){
        if(!pNode){
            count++;
            return new TreeNode<K,V>(key,value);
        }

        if(key < pNode->key){
            pNode->left = addNode(pNode->left,key,value);
        } else if(key > pNode->key){
            pNode->right = addNode(pNode->right,key,value);
        } else{
            pNode->value = value;
        }

        return pNode;

    }

    void put(K key,V value){
        root = addNode(root,key,value);
    }
```

只要知道一个节点的添加，过程。那就知道整个树的过程。我们使用递归的方式。对节点开始添加。

我在里面使用的孩子表示法，每个节点只包含自己的左右孩子的指针，用来查找该节左右孩子。

addNode中每一次加入一个节点都与当前的root节点做判断，小于root节点往左边找，大于root节点就往右边找。知道找到相同就替换，不然就是找到的位置为null，则新建一个实例返回。

写一个中序遍历，来试试看究竟有没有问题。
先复习一下，前序，中序，后序遍历。
![遍历样本.png](/images/遍历样本.png)
 1.前序遍历：
先访问根节点，再访问左节点，最后访问右节点。

根据上面的图和定义，输出的节点顺序：
A - AB - ABD - ABDECF


- 2.中序遍历
先访问左节点，再访问根节点，最后访问右节点。
D - DB - DBE - DBEA - DBEAC - DBEACF

-3.后序遍历
先访问访问左节点，再访问右节点，最后根节点。
D -DE - DEB - DEBC - DEBF - DEBFC - DEBCFA

根据上面的定义，中序遍历可以使用递归来完成：
```
void inOrderVisit(TreeNode<K,V> *node,void (*fun)(K,V)){
        if(!node){
            return;
        }
        inOrderVisit(node->left,fun);
        fun(node->key,node->value);
        inOrderVisit(node->right,fun);
    }


    void inOrderVisit(void (*fun)(K,V)){
        inOrderVisit(root,fun);
    }
```

每一次，都递归左节点，中间打印，递归右节点，一旦达到了子节点为空的情况接受递归即可。思想很简单。


打印测试一下：
```
 BST<int,int> *b = new BST<int,int>();
    b->put(2,2);
    b->put(1,1);
    b->put(3,3);

    b->put(4,4);
    b->put(-5,-5);
    b->put(10,10);

    b->inOrderVisit(visit);
```

根据中序遍历：
可以得知打印结论是如下：
-5，1，2，3，4，10

![打印结果.png](/images/打印结果.png)


###二叉搜索树的删除
树这种数据结构插入还算是相对简单，但是涉及到了删除会稍微复杂一点。

试着思考，删除的话，我们可能会删除哪几种节点，第一根结点，第二非叶节点，第三叶子节点。

- 1.当我们删掉了叶子节点很简单，直接删除即可。
- 2.当我们输出非叶子节点时候，我们往往要考虑删除的节点还有孩子节点。这个时候我们往往需要把孩子节点，补上这个空缺。
-3.当我们删除的是根结点，情况如上。

以后，删除树的节点都会基于这个思考，来完善思路。

再继续思考，我们要删除节点首先要找到对应的节点，才能删除。
所以删除步骤分为以下几个步骤：
- 1.大于当前节点的key往右边找节点
- 2.小于当前节点的key往左边找节点
- 3.找到节点之后，分为以下几种情况：
  - 1.当该节点没有左右节点的时候，说明是叶子节点，直接删除即可
  - 2.当该节点只有左节点的时候，把左节点向上补
  - 3. 当该节点只有右节点的时候，把右节点向上补
  - 4.当左右都有节点的时候。如果是非根节点的一层还好说，可以找孩子补上来。但是如果是根结点或者该子树包含的多层的时候，直接找下面的孩子补上来，一定会破坏性质1或者性质2.比如说我上面的demo，我们删除2节点（一个根节点），直接把3，或者1补上来会导致一个问题，破坏了二叉搜索树，左边的节点永远小于右边的。解决办法就是从该节点找它的前驱或者后继（也就是大小排序比这个节点排在前面或后面），就能解决这个问题。也就说去找左边子树最大，或者右边子树最小。

##### 注意：当我们在情况四删除节点时候，不能轻易的清除，需要重新处理这给被移动的节点的链接。如下图：
![节点删除.png](/images/节点删除.png)
寻找该树中最大的方法(就是去找最右侧的节点)：
```
TreeNode *findMax(TreeNode *node){
        if(!node->right){
            return node;
        }

        return findMax(node->right);
    }
```


根据上面思考的结论，删除如下：
```
TreeNode<K,V> *removeNode(TreeNode<K,V> *pNode,K key){
        if(!pNode){
            return NULL;
        }

        if(key < pNode->key){
            //从左树找节点
            pNode->left = removeNode(pNode->left,key);
        } else if(key > pNode->key){
            //从右树找节点
            pNode->right = removeNode(pNode->right,key);
        } else {
//叶子节点删除
            if(!pNode->left && !pNode->right){
                delete(pNode);
                count--;
                return NULL;
            } else if(pNode->right && pNode->left){
               //两边都有节点
                TreeNode<K,V> *biggest = new TreeNode<K,V>(findMax(pNode->left));
                biggest->left = pNode->left;
                biggest->right = pNode->right;
                delete(pNode);
                count--;
                return biggest;


            } else if(pNode->right){
//右边有节点
                TreeNode<K,V> *node = new TreeNode<K,V>(pNode->right);
                delete(pNode);
                count--;
                return node;
            } else{
//左边有节点
                TreeNode<K,V> *node = new TreeNode<K,V>(pNode->left);
                delete(pNode);
                count--;
                return node;
            }
        }


        return pNode;
    }

    void remove(K key){
        removeNode(root,key);
    }
```

 来测试一下，删除一下根节点。
![根节点删除失败.png](/images/根节点删除失败.png)

怎么一回事？根节点不是更新了吗？确实更新了，但是我们这个方法不是直接替代节点，而是生成一个新的节点，把原来的根结点位置给替换调，但是我们并有删除调原来位置的节点。

所以实际上正确的删除，需要把原来的位置删掉。
```
    TreeNode<K,V> *deleteMax(TreeNode<K,V> *node){
        if(!node->right){
            TreeNode<K,V> *left = node->left;
            delete(node);
            count--;
            return left;

        }

        node->right = deleteMax(node->right);
        return node;

    }
```
同样的，我们回去找最右侧的节点，把左孩子返回了，同时删除这个重复节点。再把变化后的根节点添加回去。

```
    TreeNode<K,V> *removeNode(TreeNode<K,V> *pNode,K key){
        if(!pNode){
            return NULL;
        }

        if(key < pNode->key){
            //从左树找节点
            pNode->left = removeNode(pNode->left,key);
        } else if(key > pNode->key){
            //从右树找节点
            pNode->right = removeNode(pNode->right,key);
        } else {
            if(!pNode->left && !pNode->right){
                delete(pNode);
                count--;
                return NULL;
            } else if(pNode->right && pNode->left){
                //
                TreeNode<K,V> *biggest = new TreeNode<K,V>(findMax(pNode->left));
                biggest->left = deleteMax(pNode->left);
                biggest->right = pNode->right;
                count++;
                delete(pNode);

                return biggest;



            } else if(pNode->right){
                TreeNode<K,V> *node = new TreeNode<K,V>(pNode->right);
                delete(pNode);
                count--;
                return node;
            } else{
                TreeNode<K,V> *node = new TreeNode<K,V>(pNode->left);
                delete(pNode);
                count--;
                return node;
            }
        }


        return pNode;
    }
```
再删除调根结点看看：
![删除节点.png](/images/删除节点.png)

终于正常了。


### 二叉搜索树的查询

根据二叉搜索树的定义，扣紧定义。大的往右边树去找，小的往左边树去找
```
    TreeNode<K,V> *getValue(TreeNode<K,V> *node,K key){
        if(!node){
            return NULL;
        }

        if(key < node->key){
            //从左树找节点
            return getValue(node->left,key);
        } else if(key > node->key){
            //从右树找节点
            return getValue(node->right,key);
        } else{
            return node;
        }

    }


    V get(K key){
        TreeNode<K,V> *node = getValue(root,key);
        return node ? node->value : NULL;
    }
```

获取一下key值为10的节点
![查询结果.png](/images/查询结果.png)


至此，二叉搜索树的算法增删查全部就结束。

## 总结
二叉搜索树是一个极其基础的数据结构。这一篇不是为了给读者，只是给自己一个借口，把这些东西盲敲出来。接下来是avl平衡树，会稍微复杂一点。





